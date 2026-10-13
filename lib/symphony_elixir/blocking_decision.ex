defmodule SymphonyElixir.BlockingDecision do
  @moduledoc """
  Normalizes blocker evidence and persists the fail-closed tracker decision.
  """

  alias SymphonyElixir.{PersistenceProvider, Tracker}

  @type reason :: term()
  @type stale_reason :: :missing_scope | :state_mismatch | :run_superseded

  @doc """
  Normalizes blocker evidence for orchestration decisions.

  Missing values and strings that are empty after trimming mean no blocker.
  The exact case-insensitive token `none` is also accepted as legacy
  compatibility. Any other non-empty string remains blocker evidence.
  """
  @spec normalize_blocker(term()) :: String.t() | nil
  def normalize_blocker(nil), do: nil

  def normalize_blocker(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> if String.downcase(value) == "none", do: nil, else: value
    end
  end

  def normalize_blocker(value), do: value |> inspect() |> normalize_blocker()

  @doc "Builds the canonical persisted blocking-decision representation."
  @spec new(reason(), term(), String.t(), String.t(), map(), map()) :: map()
  def new(reason, evidence, run_id, origin_state, references \\ %{}, metadata \\ %{})
      when is_binary(run_id) and run_id != "" and is_binary(origin_state) and origin_state != "" do
    Map.merge(metadata, %{
      "reason" => decision_text(reason),
      "evidence" => decision_evidence(evidence),
      "run_id" => run_id,
      "origin_state" => origin_state,
      "decided_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "references" => references,
      "comment_status" => "pending",
      "transition_status" => "pending"
    })
  end

  @doc "Checks a canonical decision against the live Linear state and latest persisted run."
  @spec validity(map(), String.t(), String.t() | nil) :: :valid | {:stale, stale_reason()}
  def validity(%{"origin_state" => origin_state, "run_id" => run_id} = decision, live_state, latest_run_id)
      when is_binary(origin_state) and origin_state != "" and is_binary(run_id) and run_id != "" do
    expected_state = if decision["transition_status"] == "completed", do: "Blocked", else: origin_state

    cond do
      live_state != expected_state -> {:stale, :state_mismatch}
      run_id != latest_run_id -> {:stale, :run_superseded}
      true -> :valid
    end
  end

  def validity(_decision, _live_state, _latest_run_id), do: {:stale, :missing_scope}

  @spec decide(String.t(), reason(), term(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def decide(identifier, reason, evidence, run_id, origin_state, references \\ %{}) do
    persistence = PersistenceProvider.module()

    PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end)
    |> case do
      %{blocking_decision: %{} = existing} ->
        {:ok, existing}

      issue when is_map(issue) ->
        persist_decision(persistence, issue, reason, evidence, run_id, origin_state, references)

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, :issue_not_persisted}
    end
  end

  @spec advance_no_progress(String.t(), String.t(), String.t(), map()) ::
          {:streak, pos_integer()} | {:blocked, map()} | {:error, term()}
  def advance_no_progress(identifier, run_id, origin_state, references \\ %{}) do
    persistence = PersistenceProvider.module()

    with issue when is_map(issue) <-
           PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end),
         streak = (Map.get(issue, :no_progress_streak) || 0) + 1,
         {:ok, updated} <- persistence.update_issue(issue, %{no_progress_streak: streak}) do
      advance_streak(persistence, updated, streak, run_id, origin_state, references)
    else
      nil -> {:error, :issue_not_persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp advance_streak(persistence, issue, streak, run_id, origin_state, references) do
    if streak >= 2 do
      case persist_decision(
             persistence,
             issue,
             :no_progress,
             "#{streak} completed runs without progress",
             run_id,
             origin_state,
             references
           ) do
        {:ok, decision} -> {:blocked, decision}
        {:error, reason} -> {:error, reason}
      end
    else
      {:streak, streak}
    end
  end

  @spec clear(String.t(), module()) ::
          {:ok, :already_cleared | {:cleared, %{issue_id: String.t(), run_id: String.t()}}}
          | {:error, term()}
  def clear(identifier, persistence \\ PersistenceProvider.module()) do
    case PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end) do
      %{blocking_decision: %{} = decision} = issue ->
        case persistence.update_issue(issue, %{blocking_decision: nil, no_progress_streak: 0}) do
          {:ok, _issue} ->
            {:ok,
             {:cleared,
              %{
                issue_id: Map.fetch!(issue, :tracker_issue_id),
                run_id: Map.fetch!(decision, "run_id")
              }}}

          {:error, reason} ->
            {:error, reason}
        end

      issue when is_map(issue) or is_nil(issue) ->
        {:ok, :already_cleared}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Clears a stale decision and records its original scope as a durable event."
  @spec clear_stale(String.t(), map(), String.t(), stale_reason(), module()) ::
          {:ok, map()} | :replaced | {:error, term()}
  def clear_stale(identifier, decision, source, cause, persistence \\ PersistenceProvider.module()) do
    with issue when is_map(issue) <-
           PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end),
         {:ok, :cleared} <- persistence.compare_and_clear_blocking_decision(identifier, decision),
         {:ok, event} <-
           persistence.record_event(%{
             run_id: decision["run_id"],
             issue_identifier: identifier,
             event_type: "issue.blocking_decision_cleared",
             payload: %{
               "source" => source,
               "cause" => Atom.to_string(cause),
               "issue_id" => Map.get(issue, :tracker_issue_id),
               "reason" => decision["reason"],
               "origin_state" => decision["origin_state"],
               "run_id" => decision["run_id"],
               "decided_at" => decision["decided_at"]
             }
           }) do
      {:ok, event}
    else
      nil -> {:error, :issue_not_persisted}
      {:ok, :replaced} -> :replaced
      {:error, reason} -> {:error, reason}
    end
  end

  @spec deliver(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def deliver(issue_id, identifier) do
    persistence = PersistenceProvider.module()

    with issue when is_map(issue) <-
           PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end),
         %{} = decision <- Map.get(issue, :blocking_decision) do
      comment_result = maybe_comment(issue_id, identifier, decision)
      transition_result = maybe_transition(issue_id, decision)

      updated =
        decision
        |> Map.put("comment_status", delivery_status(comment_result))
        |> Map.put("transition_status", delivery_status(transition_result))

      case persistence.update_issue(issue, %{blocking_decision: updated}) do
        {:ok, _issue} ->
          {:ok, %{decision: updated, comment: comment_result, transition: transition_result}}

        {:error, reason} ->
          {:error, {:delivery_evidence_persist_failed, reason}}
      end
    else
      nil -> {:error, :issue_not_persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fail_delivery(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def fail_delivery(identifier, reason) do
    persistence = PersistenceProvider.module()

    with issue when is_map(issue) <-
           PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end),
         %{} = decision <- Map.get(issue, :blocking_decision) do
      comment_result = {:error, reason}
      transition_result = {:error, reason}

      updated =
        decision
        |> put_delivery_failure("comment_status", reason)
        |> put_delivery_failure("transition_status", reason)

      case persistence.update_issue(issue, %{blocking_decision: updated}) do
        {:ok, _issue} ->
          {:ok, %{decision: updated, comment: comment_result, transition: transition_result}}

        {:error, reason} ->
          {:error, {:delivery_evidence_persist_failed, reason}}
      end
    else
      nil -> {:error, :issue_not_persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_comment(_issue_id, _identifier, %{"comment_status" => "completed"}), do: :ok

  defp maybe_comment(issue_id, identifier, decision),
    do: Tracker.create_comment(issue_id, comment(identifier, decision))

  defp maybe_transition(_issue_id, %{"transition_status" => "completed"}), do: :ok
  defp maybe_transition(issue_id, _decision), do: Tracker.update_issue_state(issue_id, "Blocked")
  defp delivery_status(:ok), do: "completed"
  defp delivery_status({:error, reason}), do: %{"failed" => inspect(reason)}

  defp put_delivery_failure(decision, status_key, reason) do
    case Map.get(decision, status_key) do
      "completed" -> decision
      _status -> Map.put(decision, status_key, delivery_status({:error, reason}))
    end
  end

  defp comment(identifier, decision) do
    "Symphony blocked #{identifier}.\n\nReason: #{decision["reason"]}\nEvidence: #{inspect(decision["evidence"])}\nRun: #{decision["run_id"]}\nUTC: #{decision["decided_at"]}\nReferences: #{inspect(decision["references"] || %{})}"
  end

  defp persist_decision(persistence, issue, reason, evidence, run_id, origin_state, references) do
    decision = new(reason, evidence, run_id, origin_state, references)

    case persistence.update_issue(issue, %{blocking_decision: decision}) do
      {:ok, _issue} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decision_text(value) when is_binary(value), do: String.slice(value, 0, 4_000)
  defp decision_text(value) when is_atom(value), do: Atom.to_string(value)
  defp decision_text(value), do: value |> inspect(limit: 50, printable_limit: 4_000) |> String.slice(0, 4_000)

  defp decision_evidence(value) when is_map(value) or is_list(value), do: value
  defp decision_evidence(value), do: decision_text(value)
end

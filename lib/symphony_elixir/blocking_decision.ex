defmodule SymphonyElixir.BlockingDecision do
  @moduledoc """
  Normalizes blocker evidence and persists the fail-closed tracker decision.
  """

  alias SymphonyElixir.{PersistenceProvider, Tracker}

  @type reason :: :reported_blocker | :implementation_handoff_failure | :merge_conflict | :no_progress

  @spec normalize_blocker(term()) :: String.t() | nil
  def normalize_blocker(nil), do: nil

  def normalize_blocker(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> if String.downcase(value) == "none", do: nil, else: value
    end
  end

  def normalize_blocker(value), do: value |> inspect() |> normalize_blocker()

  @spec terminal_handoff_failure?(term()) :: boolean()
  def terminal_handoff_failure?({:implementation_handoff_failed, _reason}), do: true
  def terminal_handoff_failure?({:implementation_handoff_field_required, _field}), do: true
  def terminal_handoff_failure?(:implementation_handoff_unavailable), do: true
  def terminal_handoff_failure?(_reason), do: false

  @spec decide(String.t(), reason(), term(), String.t() | nil, map()) ::
          {:ok, map()} | {:error, term()}
  def decide(identifier, reason, evidence, run_id, references \\ %{}) do
    persistence = PersistenceProvider.module()

    PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end)
    |> case do
      %{blocking_decision: %{} = existing} ->
        {:ok, existing}

      issue when is_map(issue) ->
        persist_decision(persistence, issue, reason, evidence, run_id, references)

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, :issue_not_persisted}
    end
  end

  @spec advance_no_progress(String.t(), String.t() | nil, map()) ::
          {:streak, pos_integer()} | {:blocked, map()} | {:error, term()}
  def advance_no_progress(identifier, run_id, references \\ %{}) do
    persistence = PersistenceProvider.module()

    with issue when is_map(issue) <-
           PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end),
         streak = (Map.get(issue, :no_progress_streak) || 0) + 1,
         {:ok, updated} <- persistence.update_issue(issue, %{no_progress_streak: streak}) do
      advance_streak(persistence, updated, streak, run_id, references)
    else
      nil -> {:error, :issue_not_persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp advance_streak(persistence, issue, streak, run_id, references) do
    if streak >= 2 do
      case persist_decision(
             persistence,
             issue,
             :no_progress,
             "#{streak} completed runs without progress",
             run_id,
             references
           ) do
        {:ok, decision} -> {:blocked, decision}
        {:error, reason} -> {:error, reason}
      end
    else
      {:streak, streak}
    end
  end

  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(identifier) do
    persistence = PersistenceProvider.module()

    case PersistenceProvider.read(fn -> persistence.get_issue_by_identifier(identifier) end) do
      issue when is_map(issue) ->
        case persistence.update_issue(issue, %{blocking_decision: nil, no_progress_streak: 0}) do
          {:ok, _issue} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        :ok

      {:error, reason} ->
        {:error, reason}
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

      attrs =
        if transition_result == :ok,
          do: %{blocking_decision: updated, state: "Blocked"},
          else: %{blocking_decision: updated}

      case persistence.update_issue(issue, attrs) do
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

  defp comment(identifier, decision) do
    "Symphony blocked #{identifier}.\n\nReason: #{decision["reason"]}\nEvidence: #{decision["evidence"]}\nRun: #{decision["run_id"] || "n/a"}\nUTC: #{decision["decided_at"]}\nReferences: #{inspect(decision["references"] || %{})}"
  end

  defp persist_decision(persistence, issue, reason, evidence, run_id, references) do
    decision = %{
      "reason" => Atom.to_string(reason),
      "evidence" => to_string(evidence),
      "run_id" => run_id,
      "decided_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "references" => references,
      "comment_status" => "pending",
      "transition_status" => "pending"
    }

    case persistence.update_issue(issue, %{blocking_decision: decision}) do
      {:ok, _issue} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule SymphonyElixir.MergeConflictReconciler do
  @moduledoc """
  Reconciles exact Ready-to-Merge pull request handoffs in the control plane.
  """

  require Logger

  alias SymphonyElixir.{BlockingDecision, PersistenceProvider, Tracker}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue

  @ready_to_merge "Ready to Merge"

  @type result :: :unchanged | :stale | {:blocked, map(), term()} | {:error, term()}

  @spec reconcile(Issue.t(), map(), keyword()) :: result()
  def reconcile(%Issue{} = issue, project, opts \\ []) do
    mergeability = Keyword.get(opts, :mergeability, &PullRequest.mergeability/3)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    delivery = Keyword.get(opts, :delivery, &BlockingDecision.deliver/2)

    with {:ok, handoff} <- handoff_evidence(issue.identifier),
         {:ok, pull_request} <- mergeability.(issue, project, github_opts(opts)),
         :ok <- exact_handoff?(pull_request, handoff),
         true <- conflicting?(pull_request),
         {:ok, fresh_issue} <- ready_issue(issue.id, issue_state_fetcher),
         {:ok, fresh_pull_request} <- mergeability.(fresh_issue, project, github_opts(opts)),
         :ok <- same_pull_request?(pull_request, fresh_pull_request),
         true <- conflicting?(fresh_pull_request),
         {:ok, decision} <- persist_decision(fresh_issue, fresh_pull_request, handoff),
         :ok <- persist_conflict_event(fresh_issue, fresh_pull_request, handoff),
         delivery_result <- delivery.(fresh_issue.id, fresh_issue.identifier) do
      Logger.warning(
        "GitHub merge conflict blocked issue issue_id=#{fresh_issue.id} " <>
          "issue_identifier=#{fresh_issue.identifier} pr_url=#{fresh_pull_request.url} " <>
          "run_id=#{handoff.run_id || "n/a"} raw_status=#{fresh_pull_request.raw_status}"
      )

      {:blocked, decision, delivery_result}
    else
      false ->
        :unchanged

      {:ok, nil} ->
        :unchanged

      :stale ->
        :stale

      {:error, reason} ->
        Logger.error(
          "GitHub mergeability reconciliation failed issue_id=#{issue.id} " <>
            "issue_identifier=#{issue.identifier} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp handoff_evidence(identifier) do
    persistence = PersistenceProvider.module()

    case PersistenceProvider.read(fn ->
           persistence.list_events(
             issue_identifier: identifier,
             event_type: "run.phase",
             order: :desc,
             limit: 100
           )
         end) do
      events when is_list(events) -> {:ok, latest_completed_handoff(events)}
      {:error, reason} -> {:error, {:handoff_evidence_read_failed, reason}}
    end
  end

  defp latest_completed_handoff(events) do
    case Enum.find(events, fn event ->
           value(event.payload, "phase") == "implementation_handoff" and
             value(event.payload, "status") == "completed" and
             is_binary(value(event.payload, "url"))
         end) do
      nil -> %{url: nil, repository: nil, base: nil, head: nil, run_id: nil}
      event ->
        payload = event.payload
        %{url: value(payload, "url"), repository: value(payload, "repository"),
          base: value(payload, "base"), head: value(payload, "head"), run_id: event.run_id}
    end
  end

  defp exact_handoff?(nil, _handoff), do: :ok
  defp exact_handoff?(_pull_request, %{url: nil}), do: :ok

  defp exact_handoff?(pull_request, handoff) do
    if handoff.url == pull_request.url and
         Enum.all?([:repository, :base, :head], fn field ->
           is_nil(Map.get(handoff, field)) or Map.get(handoff, field) == Map.get(pull_request, field)
         end), do: :ok, else: :stale
  end

  defp conflicting?(%{conflicting: true}), do: true
  defp conflicting?(_pull_request), do: false

  defp ready_issue(issue_id, issue_state_fetcher) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{state: @ready_to_merge} = issue]} -> {:ok, issue}
      {:ok, _issues} -> :stale
      {:error, reason} -> {:error, {:issue_state_revalidation_failed, reason}}
    end
  end

  defp same_pull_request?(pull_request, fresh_pull_request)
       when is_map(pull_request) and is_map(fresh_pull_request) do
    fields = [:url, :repository, :base, :head]
    if Enum.all?(fields, &(Map.fetch!(pull_request, &1) == Map.fetch!(fresh_pull_request, &1))), do: :ok, else: :stale
  end

  defp same_pull_request?(_pull_request, _fresh_pull_request), do: :stale

  defp persist_decision(issue, pull_request, handoff) do
    references = %{"pr_url" => pull_request.url}
    references = if handoff.run_id, do: Map.put(references, "handoff_run_id", handoff.run_id), else: references

    evidence = "merge conflict (GitHub status: #{pull_request.raw_status})"

    BlockingDecision.decide(
      issue.identifier,
      :merge_conflict,
      evidence,
      handoff.run_id,
      references
    )
  end

  defp github_opts(opts), do: Keyword.get(opts, :github_opts, [])

  defp persist_conflict_event(issue, pull_request, handoff) do
    persistence = PersistenceProvider.module()

    attrs = %{
      run_id: handoff.run_id,
      issue_identifier: issue.identifier,
      event_type: "issue.merge_conflict_detected",
      payload: %{
        issue_id: issue.id,
        pr_url: pull_request.url,
        repository: pull_request.repository,
        base: pull_request.base,
        head: pull_request.head,
        raw_status: pull_request.raw_status,
        handoff_run_id: handoff.run_id
      }
    }

    case PersistenceProvider.read(fn ->
           persistence.list_events(
             issue_identifier: issue.identifier,
             event_type: "issue.merge_conflict_detected",
             limit: 20
           )
         end) do
      events when is_list(events) ->
        if Enum.any?(events, &(value(&1.payload, "pr_url") == pull_request.url)) do
          :ok
        else
          record_conflict_event(persistence, attrs)
        end

      {:error, reason} ->
        {:error, {:merge_conflict_event_read_failed, reason}}
    end
  end

  defp record_conflict_event(persistence, attrs) do
    case persistence.record_event(attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, {:merge_conflict_event_persist_failed, reason}}
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  end
end

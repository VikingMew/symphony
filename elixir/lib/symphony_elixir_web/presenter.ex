defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.Codex.MessageHumanizer
  alias SymphonyElixir.{Config, Linear.Health, Orchestrator}
  alias SymphonyElixirWeb.{LinearStatusSignal, RateLimitStatus}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          rate_limit_status: RateLimitStatus.from_snapshot(snapshot),
          linear_status: Health.latest() |> LinearStatusSignal.from_health(),
          operator_tasks: Map.get(snapshot, :operator_tasks, %{}),
          polling: Map.get(snapshot, :polling, %{listening?: false})
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      blocked: blocked && blocked_issue_payload(blocked),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || (blocked && blocked_events_payload(blocked)) || [],
      last_error: (retry && retry.error) || (blocked && blocked.detail),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, _retry, blocked) when not is_nil(blocked), do: "blocked"
  defp issue_status(_running, nil, nil), do: "running"
  defp issue_status(nil, _retry, nil), do: "retrying"
  defp issue_status(_running, _retry, nil), do: "running"

  defp running_entry_payload(entry) do
    payload = %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      state: Map.get(entry, :state),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: Map.get(entry, :last_codex_event),
      last_message: summarize_message(Map.get(entry, :last_codex_message)),
      started_at: iso8601(Map.get(entry, :started_at)),
      last_event_at: iso8601(Map.get(entry, :last_codex_timestamp)),
      session_history: session_history_payload(Map.get(entry, :session_history, [])),
      session_history_total_count: session_history_total_count(entry),
      tokens: %{
        input_tokens: Map.get(entry, :codex_input_tokens, 0),
        output_tokens: Map.get(entry, :codex_output_tokens, 0),
        total_tokens: Map.get(entry, :codex_total_tokens, 0)
      }
    }

    payload
    |> maybe_put_non_default(:kind, Map.get(entry, :kind), "issue")
    |> maybe_put_present(:profile, Map.get(entry, :profile))
    |> maybe_put_present(:label, Map.get(entry, :label))
    |> maybe_put_present(:run_id, Map.get(entry, :run_id))
  end

  defp maybe_put_non_default(map, _key, default, default), do: map
  defp maybe_put_non_default(map, _key, nil, _default), do: map
  defp maybe_put_non_default(map, key, value, _default), do: Map.put(map, key, value)

  defp maybe_put_present(map, _key, nil), do: map
  defp maybe_put_present(map, _key, ""), do: map
  defp maybe_put_present(map, key, value), do: Map.put(map, key, value)

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      reason: entry.reason,
      detail: entry.detail,
      blocked_at: iso8601(entry.blocked_at),
      session_history: session_history_payload(Map.get(entry, :session_history, [])),
      session_history_total_count: session_history_total_count(entry)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp session_history_payload(events) when is_list(events) do
    Enum.map(events, fn event ->
      %{
        at: iso8601(Map.get(event, :at)),
        event: Map.get(event, :event),
        label: Map.get(event, :label) || to_string(Map.get(event, :event) || ""),
        detail: Map.get(event, :detail),
        severity: Map.get(event, :severity) || :info,
        metadata: Map.get(event, :metadata, %{})
      }
    end)
  end

  defp session_history_payload(_events), do: []

  defp session_history_total_count(entry) when is_map(entry) do
    Map.get(entry, :session_history_total_count) || length(Map.get(entry, :session_history, []))
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      reason: blocked.reason,
      detail: blocked.detail,
      blocked_at: iso8601(blocked.blocked_at)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host)) || (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp blocked_events_payload(blocked) do
    [
      %{
        at: iso8601(blocked.blocked_at),
        event: blocked.reason,
        message: blocked.detail
      }
    ]
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: MessageHumanizer.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end

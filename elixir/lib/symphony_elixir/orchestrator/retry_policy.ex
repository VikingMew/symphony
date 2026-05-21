defmodule SymphonyElixir.Orchestrator.RetryPolicy do
  @moduledoc """
  Pure retry and stall calculations for orchestrator runs.
  """

  import Bitwise, only: [<<<: 2]

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000

  @type retry_metadata :: %{
          optional(:identifier) => String.t(),
          optional(:error) => String.t(),
          optional(:worker_host) => String.t(),
          optional(:workspace_path) => String.t(),
          optional(:delay_type) => atom()
        }

  @spec prepare_retry(String.t(), integer() | nil, retry_metadata(), map(), pos_integer()) :: map()
  def prepare_retry(issue_id, attempt, metadata, previous_retry, max_backoff_ms)
      when is_binary(issue_id) and is_map(metadata) and is_map(previous_retry) do
    next_attempt = next_attempt(attempt, previous_retry)

    %{
      attempt: next_attempt,
      delay_ms: retry_delay(next_attempt, metadata, max_backoff_ms),
      old_timer_ref: Map.get(previous_retry, :timer_ref),
      identifier: pick_retry_identifier(issue_id, previous_retry, metadata),
      error: pick_retry_error(previous_retry, metadata),
      worker_host: pick_retry_worker_host(previous_retry, metadata),
      workspace_path: pick_retry_workspace_path(previous_retry, metadata),
      delay_type: Map.get(metadata, :delay_type)
    }
  end

  @spec retry_entry(map(), reference() | nil, reference(), integer()) :: map()
  def retry_entry(prepared_retry, timer_ref, retry_token, due_at_ms)
      when is_map(prepared_retry) and is_reference(retry_token) and is_integer(due_at_ms) do
    %{
      attempt: prepared_retry.attempt,
      timer_ref: timer_ref,
      retry_token: retry_token,
      due_at_ms: due_at_ms,
      identifier: prepared_retry.identifier,
      error: prepared_retry.error,
      worker_host: prepared_retry.worker_host,
      workspace_path: prepared_retry.workspace_path
    }
  end

  @spec pop_retry_attempt(map(), String.t(), reference()) ::
          {:ok, integer(), map(), map()} | :missing
  def pop_retry_attempt(retry_attempts, issue_id, retry_token)
      when is_map(retry_attempts) and is_binary(issue_id) and is_reference(retry_token) do
    case Map.get(retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, Map.delete(retry_attempts, issue_id)}

      _ ->
        :missing
    end
  end

  @spec stall_decision(String.t(), map(), DateTime.t(), integer()) :: {:stalled, map()} | :active
  def stall_decision(issue_id, running_entry, now, timeout_ms)
      when is_binary(issue_id) and is_map(running_entry) and is_integer(timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if timeout_ms > 0 and is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)

      {:stalled,
       %{
         issue_id: issue_id,
         identifier: identifier,
         session_id: running_entry_session_id(running_entry),
         elapsed_ms: elapsed_ms,
         attempt: next_retry_attempt_from_running(running_entry),
         metadata: %{
           identifier: identifier,
           error: "stalled for #{elapsed_ms}ms without codex activity"
         }
       }}
    else
      :active
    end
  end

  @spec stall_elapsed_ms(map(), DateTime.t()) :: integer() | nil
  def stall_elapsed_ms(running_entry, now) when is_map(running_entry) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  def stall_elapsed_ms(_running_entry, _now), do: nil

  @spec normalize_attempt(term()) :: non_neg_integer()
  def normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_attempt(_attempt), do: 0

  @spec next_retry_attempt_from_running(map()) :: pos_integer() | nil
  def next_retry_attempt_from_running(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  def next_retry_attempt_from_running(_running_entry), do: nil

  @spec retry_delay(pos_integer(), retry_metadata(), pos_integer()) :: pos_integer()
  def retry_delay(attempt, metadata, max_backoff_ms)
      when is_integer(attempt) and attempt > 0 and is_map(metadata) and is_integer(max_backoff_ms) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt, max_backoff_ms)
    end
  end

  defp next_attempt(attempt, _previous_retry) when is_integer(attempt), do: attempt
  defp next_attempt(_attempt, %{attempt: previous_attempt}) when is_integer(previous_attempt), do: previous_attempt + 1
  defp next_attempt(_attempt, _previous_retry), do: 1

  defp failure_retry_delay(attempt, max_backoff_ms) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), max_backoff_ms)
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"
end

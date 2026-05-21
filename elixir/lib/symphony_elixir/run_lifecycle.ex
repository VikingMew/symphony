defmodule SymphonyElixir.RunLifecycle do
  @moduledoc """
  Helpers for persisted run lifecycle transitions.

  Central-mode orchestration should treat a nil `finished_at` as "this run is
  active right now". This module keeps terminal run updates in one place so
  retry and restart paths do not leave stale `running` rows behind.
  """

  require Logger

  @stale_reason "runtime restarted before run finished"

  def task_event_attrs(event_type, now \\ DateTime.utc_now())

  @spec task_event_attrs(String.t(), DateTime.t()) :: map()
  def task_event_attrs("task.accepted", now), do: %{status: "running", started_at: now}
  def task_event_attrs("task.completed", now), do: terminal_attrs("completed", nil, now)
  def task_event_attrs("task.failed", now), do: terminal_attrs("failed", nil, now)
  def task_event_attrs("task.cancelled", now), do: terminal_attrs("cancelled", nil, now)
  def task_event_attrs(_event_type, _now), do: %{}

  def run_event_attrs(event_type, now \\ DateTime.utc_now())

  @spec run_event_attrs(String.t(), DateTime.t()) :: map()
  def run_event_attrs("task.accepted", _now), do: %{status: "running"}
  def run_event_attrs("task.completed", now), do: terminal_attrs("completed", nil, now)
  def run_event_attrs("task.failed", now), do: terminal_attrs("failed", nil, now)
  def run_event_attrs("task.cancelled", now), do: terminal_attrs("cancelled", nil, now)
  def run_event_attrs(_event_type, _now), do: %{}

  @spec terminal_attrs(String.t(), String.t() | nil, DateTime.t()) :: map()
  def terminal_attrs(status, failure_reason \\ nil, now \\ DateTime.utc_now()) when is_binary(status) do
    %{status: status, finished_at: now}
    |> maybe_put_failure_reason(failure_reason)
  end

  def finish_run(persistence, run_id, status, failure_reason, opts \\ [])

  @spec finish_run(module(), String.t() | nil, String.t(), String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, term()} | :noop
  def finish_run(_persistence, nil, _status, _failure_reason, _opts), do: :noop

  def finish_run(persistence, run_id, status, failure_reason, opts)
      when is_atom(persistence) and is_binary(run_id) and is_binary(status) do
    now = Keyword.get(opts, :finished_at, DateTime.utc_now())

    with true <- repo_available?(persistence) || {:error, :repo_unavailable},
         run when is_map(run) <- persistence.get_run(run_id) || {:error, :not_found},
         {:ok, updated} <-
           persistence.update_run(run, terminal_attrs(status, failure_reason, now)) do
      {:ok, updated}
    else
      {:error, reason} = error ->
        log_finish_failure(run_id, status, failure_reason, reason)
        error

      other ->
        log_finish_failure(run_id, status, failure_reason, other)
        {:error, other}
    end
  rescue
    error ->
      log_finish_failure(run_id, status, failure_reason, error)
      {:error, error}
  end

  @spec close_stale_running_runs(module(), keyword()) :: non_neg_integer()
  def close_stale_running_runs(persistence, opts \\ []) when is_atom(persistence) do
    if repo_available?(persistence) do
      reason = Keyword.get(opts, :reason, @stale_reason)
      now = Keyword.get(opts, :finished_at, DateTime.utc_now())

      persistence.list_runs(status: "running", limit: Keyword.get(opts, :limit, 500))
      |> Enum.reduce(0, &finish_stale_run(&1, &2, persistence, reason, now))
      |> tap(&log_stale_count(&1, reason))
    else
      0
    end
  rescue
    error ->
      Logger.warning("Unable to close stale persisted running runs reason=#{Exception.message(error)}")
      0
  end

  defp repo_available?(persistence) do
    function_exported?(persistence, :repo_available?, 0) and persistence.repo_available?()
  end

  defp finish_stale_run(run, count, persistence, reason, now) do
    case finish_run(persistence, Map.get(run, :id), "failed", reason, finished_at: now) do
      {:ok, _run} -> count + 1
      _ -> count
    end
  end

  defp log_stale_count(0, _reason), do: :ok

  defp log_stale_count(count, reason) do
    Logger.warning("Closed stale persisted running runs count=#{count} reason=#{inspect(reason)}")
  end

  defp maybe_put_failure_reason(attrs, nil), do: attrs
  defp maybe_put_failure_reason(attrs, failure_reason), do: Map.put(attrs, :failure_reason, failure_reason)

  defp log_finish_failure(run_id, status, failure_reason, reason) do
    Logger.warning("Unable to mark run terminal run_id=#{run_id} status=#{status} failure_reason=#{inspect(failure_reason)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
  end
end

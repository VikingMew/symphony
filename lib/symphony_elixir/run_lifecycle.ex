defmodule SymphonyElixir.RunLifecycle do
  @moduledoc """
  The application boundary for persisted terminal run transitions.
  """

  require Logger

  alias SymphonyElixir.RunFailure

  @spec task_event_attrs(String.t(), DateTime.t()) :: map()
  def task_event_attrs(event_type, now \\ DateTime.utc_now())

  def task_event_attrs("task.accepted", now), do: %{status: "running", started_at: now}
  def task_event_attrs("task.completed", now), do: terminal_attrs("completed", :completed, now)
  def task_event_attrs(_event_type, _now), do: %{}

  @spec run_event_attrs(String.t(), :completed | RunFailure.t(), DateTime.t()) :: map()
  def run_event_attrs(event_type, terminal, now \\ DateTime.utc_now())

  def run_event_attrs("task.accepted", _terminal, _now), do: %{status: "running"}
  def run_event_attrs("task.completed", :completed, now), do: terminal_attrs("completed", :completed, now)
  def run_event_attrs("task.failed", %RunFailure{} = failure, now), do: terminal_attrs("failed", failure, now)
  def run_event_attrs("task.cancelled", %RunFailure{} = failure, now), do: terminal_attrs("cancelled", failure, now)

  @spec terminal_attrs(String.t(), :completed | RunFailure.t(), DateTime.t(), map()) :: map()
  def terminal_attrs(status, terminal, now \\ DateTime.utc_now(), extra_attrs \\ %{})

  def terminal_attrs("completed", :completed, %DateTime{} = now, extra_attrs) when is_map(extra_attrs) do
    Map.merge(extra_attrs, %{status: "completed", finished_at: now, failure_reason: nil, failure_evidence: nil})
  end

  def terminal_attrs(status, %RunFailure{} = failure, %DateTime{} = now, extra_attrs)
      when status in ["failed", "blocked", "cancelled", "stopped"] and is_map(extra_attrs) do
    Map.merge(
      extra_attrs,
      Map.merge(%{status: status, finished_at: now}, RunFailure.terminal_fields(failure))
    )
  end

  @spec finish_run(module(), String.t() | nil, String.t(), :completed | RunFailure.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | :noop
  def finish_run(persistence, run_id, status, terminal, opts \\ [])

  def finish_run(_persistence, nil, _status, _terminal, _opts), do: :noop

  def finish_run(persistence, run_id, status, terminal, opts)
      when is_atom(persistence) and is_binary(run_id) and is_binary(status) do
    now = Keyword.get(opts, :finished_at, DateTime.utc_now())
    extra_attrs = Keyword.get(opts, :attrs, %{})

    with true <- repo_available?(persistence) || {:error, :repo_unavailable},
         run when is_map(run) <- persistence.get_run(run_id) || {:error, :not_found},
         {:ok, updated} <- persistence.update_run(run, terminal_attrs(status, terminal, now, extra_attrs)) do
      {:ok, updated}
    else
      {:error, reason} = error ->
        log_finish_failure(run_id, status, terminal, reason)
        error

      other ->
        log_finish_failure(run_id, status, terminal, other)
        {:error, other}
    end
  end

  @spec close_stale_running_runs(module(), keyword()) :: non_neg_integer()
  def close_stale_running_runs(persistence, opts \\ []) when is_atom(persistence) do
    if repo_available?(persistence) do
      now = Keyword.get(opts, :finished_at, DateTime.utc_now())
      failure = RunFailure.classify({:worker_process_termination, %{reason: "runtime_restart", phase: "reconciliation"}})

      persistence.list_runs(status: "running", limit: Keyword.get(opts, :limit, 500))
      |> Enum.reduce(0, &finish_stale_run(&1, &2, persistence, failure, now))
      |> tap(&log_stale_count/1)
    else
      0
    end
  end

  defp repo_available?(persistence) do
    function_exported?(persistence, :repo_available?, 0) and persistence.repo_available?()
  end

  defp finish_stale_run(run, count, persistence, failure, now) do
    case finish_run(persistence, Map.get(run, :id), "failed", failure, finished_at: now) do
      {:ok, _run} -> count + 1
      _ -> count
    end
  end

  defp log_stale_count(0), do: :ok

  defp log_stale_count(count) do
    Logger.warning("Closed stale persisted running runs count=#{count} classification=worker_process_termination")
  end

  defp log_finish_failure(run_id, status, terminal, reason) do
    Logger.warning("Unable to mark run terminal run_id=#{run_id} status=#{status} terminal=#{inspect(terminal)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
  end
end

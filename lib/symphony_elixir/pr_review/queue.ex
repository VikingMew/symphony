defmodule SymphonyElixir.PRReview.Queue do
  @moduledoc "Persistent, independently capacity-limited post-handoff review queue."

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, PersistenceEventWriter, PRReview.Delivery, PRReview.Runner, Tracker}
  alias SymphonyElixir.PRReview.Store

  @reconcile_limit 25
  @poll_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec wake() :: :ok
  def wake do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :wake)
    :ok
  end

  @impl true
  def init(opts) do
    Store.recover_running()
    Process.send_after(self(), :poll, 0)
    {:ok, %{running: %{}, opts: opts}}
  end

  @impl true
  def handle_cast(:wake, state), do: {:noreply, dispatch(state)}

  @impl true
  def handle_info(:poll, state) do
    reconcile_intents(state.opts)
    Process.send_after(self(), :poll, Keyword.get(state.opts, :poll_ms, @poll_ms))
    {:noreply, dispatch(state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {job_id, running} = Map.pop!(state.running, ref)
    finish(job_id, result, state.opts)
    {:noreply, dispatch(%{state | running: running})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {job_id, running} ->
        finish(job_id, {:error, {:review_process_down, reason}}, state.opts)
        {:noreply, dispatch(%{state | running: running})}
    end
  end

  defp dispatch(state) do
    capacity = max_concurrency(state.opts) - map_size(state.running)

    if capacity > 0 do
      Store.queued(capacity)
      |> Enum.reduce(state, &start_job/2)
    else
      state
    end
  end

  defp start_job(job, state) do
    case Store.claim(job.id) do
      {:ok, claimed} ->
        task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> execute(claimed, state.opts) end)
        %{state | running: Map.put(state.running, task.ref, claimed.id)}

      :stale ->
        state
    end
  end

  defp execute(job, opts) do
    event(job, "started", %{})

    result =
      if is_map(job.result) do
        Delivery.deliver(job)
      else
        reviewer = Keyword.get(opts, :reviewer, &Runner.run/2)

        case reviewer.(job, Keyword.get(opts, :runner_opts, [])) do
          {:ok, review_result} ->
            result = stringify_result(review_result)
            {:ok, job} = Store.update(job, %{result: result, status: "queued"})
            Delivery.deliver(job)

          other ->
            other
        end
      end

    result
  end

  defp finish(_job_id, {:ok, job}, _opts) do
    finish_run(job, "completed", nil)
    event(job, "completed", %{"outcome" => job.result["outcome"]})
  end

  defp finish(job_id, {:superseded, reason}, _opts) do
    job = SymphonyElixir.Repo.get!(SymphonyElixir.Persistence.ReviewJob, job_id)
    {:ok, job} = Store.update(job, %{status: "superseded", finished_at: DateTime.utc_now()})
    finish_run(job, "cancelled", inspect(reason))
    event(job, "superseded", %{"reason" => inspect(reason)})
  end

  defp finish(job_id, {:error, reason}, _opts) do
    job = SymphonyElixir.Repo.get!(SymphonyElixir.Persistence.ReviewJob, job_id)

    attrs =
      if is_map(job.result),
        do: %{status: "queued", delivery: Map.put(job.delivery, "last_error", inspect(reason))},
        else: %{status: "failed", finished_at: DateTime.utc_now()}

    {:ok, job} = Store.update(job, attrs)
    if job.status == "failed", do: finish_run(job, "failed", inspect(reason))
    event(job, "failed", %{"reason" => inspect(reason)})
  end

  defp reconcile_intents(opts) do
    state_fetcher = Keyword.get(opts, :state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    Enum.each(Store.intents(@reconcile_limit), fn job ->
      case state_fetcher.([job.tracker_issue_id]) do
        {:ok, [%{state: "Ready to Merge"}]} ->
          {:ok, armed} = Store.arm(job)
          event(armed, "queued", %{"source" => "reconciliation"})

        _ ->
          :ok
      end
    end)
  end

  defp max_concurrency(opts) do
    agent = Config.settings!().agent
    min(Keyword.get(opts, :max_concurrency, agent.max_concurrent_reviews), agent.max_concurrent_agents)
  end

  defp stringify_result(result) do
    result
    |> Map.update!(:outcome, &Atom.to_string/1)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp event(job, status, extra) do
    PersistenceEventWriter.record(
      %{
        project_id: job.project_id,
        run_id: job.run_id,
        issue_identifier: job.issue_identifier,
        event_type: "run.phase",
        payload:
          Map.merge(
            %{
              "phase" => "pr_review",
              "status" => status,
              "issue_id" => job.tracker_issue_id,
              "review_job_id" => job.id,
              "profile" => "review",
              "pr_url" => job.pr_url,
              "head_oid" => job.head_oid
            },
            extra
          )
      },
      %{issue_id: job.tracker_issue_id, issue_identifier: job.issue_identifier, run_id: job.run_id}
    )
  end

  defp finish_run(job, status, reason),
    do: SymphonyElixir.Persistence.finish_run(job.run_id, status, reason)
end

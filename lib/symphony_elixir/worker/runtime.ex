defmodule SymphonyElixir.Worker.Runtime do
  @moduledoc false
  use GenServer

  alias SymphonyElixir.Worker.{Cleanup, Client, Config, Executor, Paths}

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    Process.send_after(self(), :register, 0)
    Process.send_after(self(), :cleanup, 0)
    {:ok, %{config: config, identity: nil, active: %{}, heartbeat_seconds: 10}}
  end

  @impl true
  def handle_info(:register, state) do
    case Client.register(state.config) do
      {:ok, response} ->
        identity = %{
          "worker_id" => response["worker_id"],
          "session_id" => response["session_id"],
          "protocol_version" => Client.protocol_version()
        }

        schedule(:poll, 0)
        heartbeat_seconds = response["heartbeat_interval_seconds"] || 10
        schedule(:heartbeat, heartbeat_seconds)
        {:noreply, %{state | identity: identity, heartbeat_seconds: heartbeat_seconds}}

      {:error, _reason} ->
        schedule(:register, 5)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{identity: identity} = state) when not is_nil(identity) do
    claim_request =
      Map.merge(identity, %{
        "available_slots" => max(state.config.slots - map_size(state.active), 0),
        "capabilities" => %{"execution" => ["v1"]}
      })

    next =
      case Client.claim(state.config, claim_request) do
        {:ok, %{"task" => nil}} -> state
        {:ok, %{"task_id" => task_id} = claim} -> start_claim(state, task_id, claim)
        {:error, {:http_error, 401, _body}} -> recover_session(state)
        _ -> state
      end

    schedule(:poll, 5)
    {:noreply, next}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(:heartbeat, %{identity: identity} = state) when not is_nil(identity) do
    leases = Enum.map(state.active, fn {_task_id, %{claim: claim}} -> claim["lease_id"] end)

    next =
      case Client.heartbeat(state.config, identity, %{
             active_leases: leases,
             available_slots: max(state.config.slots - map_size(state.active), 0)
           }) do
        {:ok, %{"commands" => commands}} when is_list(commands) ->
          commands
          |> Enum.filter(&(&1["type"] == "cancel_task"))
          |> Enum.reduce(state, &cancel/2)

        {:error, {:http_error, 401, _body}} ->
          recover_session(state)

        _ ->
          state
      end

    if next.identity, do: schedule(:heartbeat, next.heartbeat_seconds)
    {:noreply, next}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Enum.find(state.active, fn {_task_id, active} -> active.ref == ref end) do
      {task_id, _active} ->
        Process.demonitor(ref, [:flush])
        payload = SymphonyElixir.Redaction.payload(result, 4_096)
        Client.event(state.config, state.identity, task_id, terminal_type(result), payload)
        {:noreply, %{state | active: Map.delete(state.active, task_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:cleanup, state) do
    active =
      state.active
      |> Enum.flat_map(fn {_task_id, %{claim: claim}} ->
        with {:ok, workspace} <- Paths.lease_dir(state.config, claim["project_id"], claim["task_id"], claim["lease_id"]),
             {:ok, log_dir} <- Paths.log_dir(state.config, claim["task_id"], claim["lease_id"]) do
          [workspace, log_dir]
        else
          _ -> []
        end
      end)
      |> MapSet.new()

    now = DateTime.utc_now()
    workspace_targets = Cleanup.descendants_at_depth(state.config.workspace_root, 3)
    log_targets = Cleanup.descendants_at_depth(state.config.log_root, 2)
    _ = Cleanup.sweep(state.config.workspace_root, workspace_targets, active, state.config.retention_seconds, now)
    _ = Cleanup.sweep(state.config.log_root, log_targets, active, state.config.retention_seconds, now)
    _ = Cleanup.evict_cache(state.config.cache_root, state.config.cache_max_bytes, state.config.retention_seconds, now)
    schedule(:cleanup, 300)
    {:noreply, state}
  end

  defp start_claim(state, task_id, claim) do
    if map_size(state.active) < state.config.slots and not Map.has_key?(state.active, task_id) do
      Client.event(state.config, state.identity, task_id, "task.accepted", %{phase: "accepted"})
      Client.event(state.config, state.identity, task_id, "task.progress", %{phase: "execution_started"})
      task = Task.Supervisor.async_nolink(SymphonyElixir.Worker.TaskSupervisor, fn -> Executor.execute(state.config, claim) end)
      %{state | active: Map.put(state.active, task_id, %{ref: task.ref, pid: task.pid, claim: claim})}
    else
      state
    end
  end

  defp cancel(%{"task_id" => task_id}, state) do
    case Map.get(state.active, task_id) do
      nil ->
        state

      %{pid: pid} = lease ->
        Process.exit(pid, :shutdown)
        %{state | active: Map.put(state.active, task_id, Map.put(lease, :cancelling, true))}
    end
  end

  defp cancel(_, state), do: state
  defp terminal_type(%{status: :completed}), do: "task.completed"
  defp terminal_type(%{status: :cancelled}), do: "task.cancelled"
  defp terminal_type(_), do: "task.failed"

  defp recover_session(state) do
    Enum.each(state.active, fn {_task_id, lease} -> Process.exit(lease.pid, :shutdown) end)
    schedule(:register, 0)
    %{state | identity: nil, active: %{}}
  end

  defp schedule(message, seconds), do: Process.send_after(self(), message, seconds * 1_000)
end

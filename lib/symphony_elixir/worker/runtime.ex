defmodule SymphonyElixir.Worker.Runtime do
  @moduledoc false
  use GenServer

  alias SymphonyElixir.Worker.{Client, Config, Executor}

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    Process.send_after(self(), :register, 0)
    {:ok, %{config: config, identity: nil, active: %{}}}
  end

  @impl true
  def handle_info(:register, state) do
    case Client.register(state.config) do
      {:ok, response} ->
        identity = %{"worker_id" => response["worker_id"], "session_id" => response["session_id"], "protocol_version" => "worker-v1"}
        schedule(:poll, 0)
        schedule(:heartbeat, response["heartbeat_interval_seconds"] || 10)
        {:noreply, %{state | identity: identity}}

      {:error, _reason} ->
        schedule(:register, 5)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{identity: identity} = state) when not is_nil(identity) do
    next =
      case Client.claim(state.config, identity) do
        {:ok, %{"task" => nil}} -> state
        {:ok, %{"task_id" => task_id} = claim} -> start_claim(state, task_id, claim)
        _ -> state
      end

    schedule(:poll, 5)
    {:noreply, next}
  end

  def handle_info(:heartbeat, %{identity: identity} = state) when not is_nil(identity) do
    leases = Enum.map(state.active, fn {task_id, %{claim: claim}} -> %{task_id: task_id, lease_id: claim["lease_id"]} end)

    next =
      case Client.heartbeat(state.config, identity, %{active_leases: leases, available_slots: max(state.config.slots - map_size(state.active), 0)}) do
        {:ok, %{"cancel_task" => cancellations}} when is_list(cancellations) -> Enum.reduce(cancellations, state, &cancel/2)
        _ -> state
      end

    schedule(:heartbeat, 10)
    {:noreply, next}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Enum.find(state.active, fn {_task_id, active} -> active.ref == ref end) do
      {task_id, _active} ->
        Process.demonitor(ref, [:flush])
        Client.event(state.config, state.identity, task_id, terminal_type(result), result)
        {:noreply, %{state | active: Map.delete(state.active, task_id)}}

      nil -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp start_claim(state, task_id, claim) do
    if map_size(state.active) < state.config.slots and not Map.has_key?(state.active, task_id) do
      Client.event(state.config, state.identity, task_id, "task.accepted", %{phase: "accepted"})
      task = Task.Supervisor.async_nolink(SymphonyElixir.Worker.TaskSupervisor, fn -> Executor.execute(state.config, claim) end)
      %{state | active: Map.put(state.active, task_id, %{ref: task.ref, pid: task.pid, claim: claim})}
    else
      state
    end
  end

  defp cancel(%{"task_id" => task_id}, state) do
    case Map.pop(state.active, task_id) do
      {nil, _} -> state
      {%{pid: pid}, active} -> Process.exit(pid, :shutdown); %{state | active: active}
    end
  end

  defp cancel(_, state), do: state
  defp terminal_type(%{status: :completed}), do: "task.completed"
  defp terminal_type(%{status: :cancelled}), do: "task.cancelled"
  defp terminal_type(_), do: "task.failed"
  defp schedule(message, seconds), do: Process.send_after(self(), message, seconds * 1_000)
end

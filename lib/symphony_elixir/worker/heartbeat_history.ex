defmodule SymphonyElixir.Worker.HeartbeatHistory do
  @moduledoc """
  Coalesces worker heartbeat history writes outside the worker API response path.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.PersistenceProvider

  @coalesce_heartbeat_intervals 2

  @type key :: {module(), String.t(), String.t()}
  @type state :: %{
          required(:pending) => %{optional(key()) => reference()},
          required(:coalesce_ms) => non_neg_integer() | :from_persistence
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec observe(String.t(), String.t(), module(), GenServer.server()) :: :ok
  def observe(worker_id, session_id, persistence \\ PersistenceProvider.module(), server \\ __MODULE__) do
    if process_alive?(server) do
      GenServer.cast(server, {:observe, worker_id, session_id, persistence})
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{pending: %{}, coalesce_ms: Keyword.get(opts, :coalesce_ms, :from_persistence)}}
  end

  @impl true
  def handle_cast({:observe, worker_id, session_id, persistence}, state) do
    key = {persistence, worker_id, session_id}

    if Map.has_key?(state.pending, key) do
      {:noreply, state}
    else
      timer = Process.send_after(self(), {:flush, key}, coalesce_ms(state, persistence))
      {:noreply, put_in(state.pending[key], timer)}
    end
  end

  @impl true
  def handle_info({:flush, {persistence, worker_id, session_id} = key}, state) do
    {_timer, pending} = Map.pop(state.pending, key)
    start_history_write(persistence, worker_id, session_id)
    {:noreply, %{state | pending: pending}}
  end

  defp coalesce_ms(%{coalesce_ms: ms}, _persistence) when is_integer(ms), do: ms

  defp coalesce_ms(%{coalesce_ms: :from_persistence}, persistence) do
    persistence.worker_heartbeat_interval_seconds() * @coalesce_heartbeat_intervals * 1_000
  end

  defp start_history_write(persistence, worker_id, session_id) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           record_history(persistence, worker_id, session_id)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Worker heartbeat history write start failed worker_id=#{worker_id} session_id=#{session_id} persistence=#{inspect(persistence)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}"
        )
    end
  end

  defp record_history(persistence, worker_id, session_id) do
    case persistence.heartbeat_worker(worker_id, session_id) do
      {:ok, _payload} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Worker heartbeat history write failed worker_id=#{worker_id} session_id=#{session_id} persistence=#{inspect(persistence)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}"
        )
    end
  end

  defp process_alive?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp process_alive?(server) when is_pid(server), do: Process.alive?(server)
end

defmodule SymphonyElixir.Worker.HeartbeatMetrics do
  @moduledoc """
  In-memory worker API heartbeat counters for current-state observability.
  """

  use Agent

  @type snapshot :: %{required(:heartbeat_failed_attempts) => non_neg_integer()}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> initial_state() end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec record_failure(term(), GenServer.server()) :: :ok
  def record_failure(_reason, server \\ __MODULE__) do
    Agent.update(server, &Map.update!(&1, :heartbeat_failed_attempts, fn count -> count + 1 end))
  end

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: Agent.get(server, & &1)

  @spec reset!(GenServer.server()) :: :ok
  def reset!(server \\ __MODULE__), do: Agent.update(server, fn _state -> initial_state() end)

  defp initial_state, do: %{heartbeat_failed_attempts: 0}
end

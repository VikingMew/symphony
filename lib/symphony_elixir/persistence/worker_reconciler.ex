defmodule SymphonyElixir.Persistence.WorkerReconciler do
  @moduledoc false
  use GenServer

  alias SymphonyElixir.Persistence

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval_seconds = Keyword.get(opts, :interval_seconds, reconciliation_interval_seconds())
    persistence = Keyword.get(opts, :persistence, Persistence)
    send(self(), :reconcile)
    {:ok, %{interval_seconds: interval_seconds, persistence: persistence}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state.persistence.expire_stale_worker_state()
    Process.send_after(self(), :reconcile, state.interval_seconds * 1_000)
    {:noreply, state}
  end

  defp reconciliation_interval_seconds do
    :symphony_elixir
    |> Application.get_env(:worker_api, [])
    |> Keyword.get(:reconciliation_interval_seconds, 10)
  end
end

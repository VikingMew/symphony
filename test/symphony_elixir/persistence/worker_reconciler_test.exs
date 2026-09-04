defmodule SymphonyElixir.Persistence.WorkerReconcilerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Persistence.WorkerReconciler

  defmodule FakePersistence do
    def expire_stale_worker_state do
      test_pid = Agent.get(__MODULE__, & &1)
      send(test_pid, :reconciled)
      {1, 1}
    end
  end

  test "periodically expires stale worker state" do
    test_pid = self()

    start_supervised!(%{
      id: FakePersistence,
      start: {Agent, :start_link, [fn -> test_pid end, [name: FakePersistence]]}
    })

    start_supervised!({WorkerReconciler, persistence: FakePersistence, interval_seconds: 1, name: Module.concat(__MODULE__, Reconciler)})
    assert_receive :reconciled, 500
    assert_receive :reconciled, 1_500
  end
end

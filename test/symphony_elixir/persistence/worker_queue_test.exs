defmodule SymphonyElixir.Persistence.WorkerQueueTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Persistence
  alias SymphonyElixir.Persistence.WorkerQueue

  setup do
    previous_worker_api = Application.get_env(:symphony_elixir, :worker_api)
    previous_token = System.get_env("SYMPHONY_WORKER_REGISTRATION_TOKEN")

    on_exit(fn ->
      restore_app_env(:worker_api, previous_worker_api)
      restore_env("SYMPHONY_WORKER_REGISTRATION_TOKEN", previous_token)
    end)
  end

  test "exposes worker protocol and configured timing without Repo" do
    Application.put_env(:symphony_elixir, :worker_api,
      heartbeat_interval_seconds: 4,
      lease_duration_seconds: 12
    )

    assert WorkerQueue.worker_protocol_version() == "worker-api-v1"
    assert WorkerQueue.worker_heartbeat_interval_seconds() == 4
    assert WorkerQueue.worker_lease_duration_seconds() == 12
    refute Process.whereis(SymphonyElixir.Repo)
  end

  test "validates registration token from config or environment without Repo" do
    Application.put_env(:symphony_elixir, :worker_api, registration_token: "from-config")
    System.put_env("SYMPHONY_WORKER_REGISTRATION_TOKEN", "from-env")

    assert WorkerQueue.worker_registration_token() == "from-config"
    assert WorkerQueue.valid_worker_registration_token?("from-config")
    refute WorkerQueue.valid_worker_registration_token?("from-env")

    Application.put_env(:symphony_elixir, :worker_api, [])
    assert WorkerQueue.worker_registration_token() == "from-env"
    assert WorkerQueue.valid_worker_registration_token?("from-env")
  end

  test "worker queue operations return repo unavailable when Repo is not started" do
    refute Process.whereis(SymphonyElixir.Repo)

    assert WorkerQueue.register_worker(%{}) == {:error, :repo_unavailable}
    assert WorkerQueue.enqueue_task(%{}) == {:error, :project_id_required}
    assert WorkerQueue.enqueue_task(%{project_id: "project-id"}) == {:error, :repo_unavailable}
    assert WorkerQueue.claim_task("worker", "session", %{}) == {:error, :repo_unavailable}
    assert WorkerQueue.heartbeat("worker", "session", %{}) == {:error, :repo_unavailable}
    assert WorkerQueue.cancel_task("task") == {:error, :repo_unavailable}
    assert WorkerQueue.requeue_task("task") == {:error, :repo_unavailable}
    assert WorkerQueue.record_worker_task_event("worker", "session", "task", "task.completed", %{}) == {:error, :repo_unavailable}
    assert WorkerQueue.expire_stale_worker_state() == {0, 0}
  end

  test "enqueue_task validates project ownership before touching Repo" do
    assert WorkerQueue.enqueue_task(%{}) == {:error, :project_id_required}
    assert WorkerQueue.enqueue_task(%{project_id: "project-id"}) == {:error, :repo_unavailable}
  end

  test "public persistence context delegates worker queue compatibility functions" do
    Application.put_env(:symphony_elixir, :worker_api, heartbeat_interval_seconds: 7)

    assert Persistence.worker_protocol_version() == WorkerQueue.worker_protocol_version()
    assert Persistence.worker_heartbeat_interval_seconds() == 7
    assert Persistence.register_worker(%{}) == WorkerQueue.register_worker(%{})
    assert Persistence.list_workers() == WorkerQueue.list_workers()
    assert Persistence.list_worker_sessions() == WorkerQueue.list_worker_sessions()
    assert Persistence.list_tasks() == WorkerQueue.list_tasks()
    assert Persistence.list_task_leases() == WorkerQueue.list_task_leases()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

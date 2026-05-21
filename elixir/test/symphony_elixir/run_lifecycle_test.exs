defmodule SymphonyElixir.RunLifecycleTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunLifecycle
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous = Application.get_env(:symphony_elixir, :fake_persistence, [])
    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: true)
    FakePersistence.reset!()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :fake_persistence, previous)
    end)

    :ok
  end

  test "marks a run terminal with finished_at and failure reason" do
    FakePersistence.put_runs([
      %{id: "run-1", issue_identifier: "CCR-5", status: "running", started_at: ~U[2026-05-21 00:00:00Z], finished_at: nil}
    ])

    assert {:ok, %{status: "failed", failure_reason: "boom", finished_at: %DateTime{}}} =
             RunLifecycle.finish_run(FakePersistence, "run-1", "failed", "boom")
  end

  test "startup reconciliation closes stale running rows" do
    FakePersistence.put_runs([
      %{id: "run-1", issue_identifier: "CCR-5", status: "running", started_at: ~U[2026-05-21 00:00:00Z], finished_at: nil},
      %{id: "run-2", issue_identifier: "CCR-5", status: "completed", started_at: ~U[2026-05-21 00:00:00Z], finished_at: ~U[2026-05-21 00:01:00Z]}
    ])

    assert RunLifecycle.close_stale_running_runs(FakePersistence) == 1
    assert %{status: "failed", failure_reason: "runtime restarted before run finished", finished_at: %DateTime{}} = FakePersistence.get_run("run-1")
    assert %{status: "completed"} = FakePersistence.get_run("run-2")
  end

  test "task and run terminal event mappings share timestamp semantics" do
    now = ~U[2026-05-21 00:00:00Z]

    assert RunLifecycle.terminal_attrs("failed", "boom", now) == %{status: "failed", failure_reason: "boom", finished_at: now}
    assert RunLifecycle.finish_run(FakePersistence, nil, "failed", "boom") == :noop
    assert RunLifecycle.task_event_attrs("task.completed", now) == %{status: "completed", finished_at: now}
    assert RunLifecycle.task_event_attrs("task.accepted", now) == %{status: "running", started_at: now}
    assert RunLifecycle.run_event_attrs("task.completed", now) == %{status: "completed", finished_at: now}
    assert RunLifecycle.run_event_attrs("task.accepted", now) == %{status: "running"}
    assert RunLifecycle.task_event_attrs("task.failed", now) == %{status: "failed", finished_at: now}
    assert RunLifecycle.run_event_attrs("task.cancelled", now) == %{status: "cancelled", finished_at: now}
    assert RunLifecycle.task_event_attrs("unknown", now) == %{}
  end

  test "terminal updates return errors for unavailable or missing runs" do
    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: false)
    assert {:error, :repo_unavailable} = RunLifecycle.finish_run(FakePersistence, "run-missing", "failed", nil)

    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: true)
    assert {:error, :not_found} = RunLifecycle.finish_run(FakePersistence, "run-missing", "failed", nil)
  end
end

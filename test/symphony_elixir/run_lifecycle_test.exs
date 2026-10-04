defmodule SymphonyElixir.RunLifecycleTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{RunFailure, RunLifecycle}
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous = Application.get_env(:symphony_elixir, :fake_persistence, [])
    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: true)
    FakePersistence.reset!()

    on_exit(fn -> Application.put_env(:symphony_elixir, :fake_persistence, previous) end)
    :ok
  end

  test "writes typed terminal classification, evidence, and extra attrs atomically" do
    FakePersistence.put_runs([
      %{id: "run-1", issue_identifier: "CCR-5", status: "running", started_at: ~U[2026-05-21 00:00:00Z]}
    ])

    failure = RunFailure.classify({:agent_domain_failure, %{reason: "worker_error", detail: "boom"}})

    assert {:ok,
            %{
              status: "failed",
              failure_reason: "runtime_failure",
              failure_evidence: %{"detail" => "boom", "reason" => "worker_error"},
              execution_summary: %{"outcome" => "failed"},
              finished_at: %DateTime{}
            }} =
             RunLifecycle.finish_run(FakePersistence, "run-1", "failed", failure, attrs: %{execution_summary: %{"outcome" => "failed"}})
  end

  test "writes assignment expiry classification and rejection evidence together" do
    FakePersistence.put_runs([
      %{id: "run-expired", issue_identifier: "SYM-126", status: "running", started_at: ~U[2026-10-04 00:00:00Z]}
    ])

    failure =
      RunFailure.classify({:assignment_expired, %{phase: "lease", code: "invalid_worker_summary", terminal_event_type: "task.failed"}})

    assert {:ok, run} = RunLifecycle.finish_run(FakePersistence, "run-expired", "failed", failure)
    assert run.failure_reason == "assignment_expired"
    assert run.failure_evidence["code"] == "invalid_worker_summary"
    assert run.failure_evidence["reason"] == "assignment_expired"
  end

  test "startup reconciliation closes stale running rows with a process classification" do
    FakePersistence.put_runs([
      %{id: "run-1", issue_identifier: "CCR-5", status: "running", started_at: ~U[2026-05-21 00:00:00Z]},
      %{id: "run-2", issue_identifier: "CCR-5", status: "completed", started_at: ~U[2026-05-21 00:00:00Z]}
    ])

    assert RunLifecycle.close_stale_running_runs(FakePersistence) == 1

    assert %{
             status: "failed",
             failure_reason: "worker_process_termination",
             failure_evidence: %{"phase" => "reconciliation", "reason" => "runtime_restart"},
             finished_at: %DateTime{}
           } = FakePersistence.get_run("run-1")

    assert %{status: "completed"} = FakePersistence.get_run("run-2")
  end

  test "completed and non-success terminal matrices share timestamp semantics" do
    now = ~U[2026-05-21 00:00:00Z]
    failure = RunFailure.classify({:cancelled, %{reason: "operator_requested"}})

    assert RunLifecycle.terminal_attrs("completed", :completed, now) == %{
             status: "completed",
             failure_reason: nil,
             failure_evidence: nil,
             finished_at: now
           }

    assert RunLifecycle.terminal_attrs("cancelled", failure, now) == %{
             status: "cancelled",
             failure_reason: "cancelled",
             failure_evidence: %{"reason" => "operator_requested"},
             finished_at: now
           }

    assert RunLifecycle.finish_run(FakePersistence, nil, "failed", failure) == :noop
    assert RunLifecycle.task_event_attrs("task.accepted", now) == %{status: "running", started_at: now}
    assert RunLifecycle.task_event_attrs("task.failed", now) == %{}
  end

  test "terminal updates return errors for unavailable or missing runs" do
    failure = RunFailure.classify({:runtime_failure, %{reason: "worker_error"}})

    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: false)
    assert {:error, :repo_unavailable} = RunLifecycle.finish_run(FakePersistence, "run-missing", "failed", failure)

    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: true)
    assert {:error, :not_found} = RunLifecycle.finish_run(FakePersistence, "run-missing", "failed", failure)
  end
end

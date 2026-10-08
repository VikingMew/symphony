defmodule SymphonyElixir.Worker.AssignmentManagerExpiryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunFailure
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager

  setup do
    FakePersistence.reset!()
    now = DateTime.utc_now()
    name = Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")

    manager =
      start_supervised!({AssignmentManager, name: name, persistence: FakePersistence, orchestrator: self(), now: fn -> now end, reconcile_interval_ms: :timer.hours(1)})

    %{manager: manager, now: now}
  end

  test "ordinary expiry remains worker process termination", context do
    assignment = seed_assignment(context, "ordinary")
    expire_assignment(context)
    assert_late_event_rejected(context, assignment)

    assert_receive {:"$gen_cast", {:worker_task_finished, "issue-126", {:failed, _failure}}}, 1_000
    run = FakePersistence.get_run(assignment.run_id)
    assert run.failure_reason == "worker_process_termination"
    assert run.failure_evidence == %{"phase" => "lease", "reason" => "assignment_expired"}
    assert_terminal_history(assignment, run)
  end

  test "rejected terminal expiry uses sanitized rejection evidence everywhere", context do
    assignment = seed_assignment(context, "rejected")
    invalid_detail = "token=super-secret /tmp/worker/output.log"
    attempted_summary = failure_summary(invalid_detail)

    assert {:error, {:invalid_worker_summary, "gate 0: failure_detail contains a worker-local filesystem path"}} =
             AssignmentManager.record_event(
               assignment.worker_id,
               assignment.session_id,
               assignment.id,
               "task.failed",
               %{"correlation" => assignment.correlation, "summary" => attempted_summary},
               context.manager
             )

    rejection = AssignmentManager.current_assignment(context.manager).last_terminal_rejection
    assert rejection["code"] == "invalid_worker_summary"
    assert rejection["terminal_event_type"] == "task.failed"

    assert rejection["attempted"] == %{
             "phase" => "validation",
             "outcome" => "failed",
             "reason" => "non_zero",
             "validation_status" => "failed",
             "gates" => [%{"index" => 0, "status" => "failed", "exit_code" => 7}]
           }

    refute inspect(rejection) =~ invalid_detail
    refute inspect(rejection) =~ "/tmp/worker"
    refute inspect(rejection) =~ "super-secret"
    assert FakePersistence.list_events(run_id: assignment.run_id, event_type: "task.failed") == []

    expire_assignment(context)
    assert_late_event_rejected(context, assignment)

    assert_receive {:"$gen_cast", {:worker_task_finished, "issue-126", {:failed, %RunFailure{} = failure}}}, 1_000
    assert failure.classification == "assignment_expired"
    evidence = failure.evidence
    run = FakePersistence.get_run(assignment.run_id)
    assert run.failure_reason == "assignment_expired"
    assert run.failure_evidence["reason"] == "assignment_expired"
    assert run.failure_evidence["phase"] == "lease"
    assert run.failure_evidence["code"] == "invalid_worker_summary"
    assert run.failure_evidence["validator_message"] =~ "worker-local filesystem path"
    refute inspect(run.failure_evidence) =~ invalid_detail
    refute inspect(run.failure_evidence) =~ "/tmp/worker"
    refute inspect(run.failure_evidence) =~ "super-secret"
    assert_terminal_history(assignment, run)

    assert evidence == run.failure_evidence
  end

  defp seed_assignment(context, suffix) do
    run_id = "run-#{suffix}"

    {:ok, _run} =
      FakePersistence.create_run(%{
        id: run_id,
        project_id: "fake-project-id",
        issue_identifier: "SYM-126",
        status: "running",
        started_at: context.now
      })

    correlation = %{
      "project_id" => "fake-project-id",
      "run_id" => run_id,
      "issue_id" => "issue-126",
      "issue_identifier" => "SYM-126",
      "task_id" => "task-#{suffix}",
      "lease_id" => "task-#{suffix}",
      "worker_id" => "worker-1",
      "worker_session_id" => "session-1",
      "assignment_id" => "task-#{suffix}"
    }

    assignment = %{
      id: "task-#{suffix}",
      task_id: "task-#{suffix}",
      lease_id: "task-#{suffix}",
      issue: %{id: "issue-126"},
      issue_identifier: "SYM-126",
      project_id: "fake-project-id",
      run_id: run_id,
      worker_id: "worker-1",
      session_id: "session-1",
      expires_at: DateTime.add(context.now, 60, :second),
      correlation: correlation,
      last_terminal_rejection: nil
    }

    :sys.replace_state(context.manager, &%{&1 | assignment: assignment})
    assignment
  end

  defp expire_assignment(context) do
    :sys.replace_state(context.manager, fn state ->
      put_in(state.assignment.expires_at, DateTime.add(context.now, -1, :second))
    end)
  end

  defp assert_late_event_rejected(context, assignment) do
    assert {:error, :lease_not_active} =
             AssignmentManager.record_event(
               assignment.worker_id,
               assignment.session_id,
               assignment.id,
               "task.progress",
               %{},
               context.manager
             )
  end

  defp assert_terminal_history(assignment, run) do
    assert [task_event] = FakePersistence.list_events(run_id: assignment.run_id, event_type: "task.failed")
    assert [run_event] = FakePersistence.list_events(run_id: assignment.run_id, event_type: "run.failed")

    for event <- [task_event, run_event] do
      assert event.payload["failure_reason"] == run.failure_reason
      assert event.payload["failure_evidence"] == run.failure_evidence
    end
  end

  defp failure_summary(detail) do
    %{
      "phase" => "validation",
      "outcome" => "failed",
      "reason" => "non_zero",
      "occurred_at" => "2026-10-04T10:00:00Z",
      "source_revision" => "abc123",
      "runtime" => %{"image_tag" => "worker:test", "worker_source_revision" => "abc123"},
      "validation_status" => "failed",
      "gates" => [
        %{
          "name" => "check",
          "status" => "failed",
          "exit_code" => 7,
          "duration_ms" => 42,
          "timeout_ms" => 120_000,
          "failure_detail" => detail
        }
      ]
    }
  end
end

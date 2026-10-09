# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.AssignmentManager2 do
  @moduledoc false

  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixir.Worker.AssignmentManagerTest.BlockingHeartbeatPersistence
  alias SymphonyElixir.Worker.AssignmentManagerTest.BlockingReconcileTracker
  alias SymphonyElixir.Worker.AssignmentManagerTest.ConfiguredWorkflows
  alias SymphonyElixir.Worker.AssignmentManagerTest.FailingCancelPersistence
  alias SymphonyElixir.Worker.AssignmentManagerTest.ProjectTracker
  alias SymphonyElixir.Worker.AssignmentManagerTest.SlowReconcileTracker
  alias SymphonyElixir.Worker.AssignmentManagerTest.Tracker
  alias SymphonyElixir.Worker.AssignmentManagerTest.Workflows
  alias SymphonyElixir.Worker.AssignmentManagerTest.ZombieReconcilePersistence

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      import ExUnit.CaptureLog

      test "Refining latest terminal worker run can be assigned without another state update", context do
        enable_active_state("Refining")
        refining = %{issue(6) | state: "Refining"}
        Tracker.put([refining])
        {:ok, _run} = FakePersistence.create_run(%{issue_identifier: refining.identifier, status: "succeeded", started_at: context.now})

        assert {:ok, assignment} = claim(context)

        assert assignment.issue.state == "Refining"
        assert assignment.payload["issue"]["state"] == "Refining"
        assert Tracker.updates() == []
      end

      test "Codex capacity failure persists its reason, ends the assignment, and permits another claim", context do
        ready = issue(1)
        Tracker.put([ready])
        assert {:ok, assignment} = claim(context)

        terminal_summary =
          summary("failed")
          |> Map.merge(%{
            "phase" => "codex",
            "reason" => "codex_upstream_capacity",
            "validation_status" => "pending",
            "detail" => Jason.encode!(%{"detail" => %{"codex_error_info" => "serverOverloaded", "will_retry" => false}})
          })

        assert {:ok, task_event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.failed",
                   %{"correlation" => assignment.correlation, "summary" => terminal_summary},
                   context.manager
                 )

        run = FakePersistence.get_run(assignment.run_id)
        assert run.status == "failed"
        assert run.failure_reason == "codex_upstream_capacity"
        assert run.failure_evidence["reason"] == "codex_upstream_capacity"
        assert get_in(Jason.decode!(run.failure_evidence["detail"]), ["detail", "will_retry"]) == false
        assert run.execution_summary == terminal_summary
        assert task_event.payload["failure_reason"] == run.failure_reason

        assert [run_event] = FakePersistence.list_events(run_id: assignment.run_id, event_type: "run.failed")
        assert run_event.payload["failure_reason"] == run.failure_reason
        assert run_event.payload["failure_evidence"] == run.failure_evidence

        Tracker.put([])
        assert {:ok, {:empty, 5}} = claim(context)
        Tracker.put([ready])
        assert {:ok, next} = claim(context)
        assert next.id == assignment.id == false
        assert next.run_id == assignment.run_id == false
      end

      test "legal succeeded worker outcome persists completed without failure fields", context do
        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.failed",
                   %{"correlation" => assignment.correlation, "summary" => summary("succeeded")},
                   context.manager
                 )

        run = FakePersistence.get_run(assignment.run_id)
        assert run.status == "completed"
        assert run.failure_reason == nil
        assert run.failure_evidence == nil
        assert run.execution_summary == summary("succeeded")
        assert [_event] = FakePersistence.list_events(run_id: assignment.run_id, event_type: "run.completed")
      end

      test "heartbeat renews only the owning assignment and stale events are rejected", context do
        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        assert {:ok, %{lease_renewals: []}} =
                 AssignmentManager.heartbeat(context.worker.id, context.session.id, %{"active_leases" => ["wrong"]}, context.manager)

        assert {:ok, %{lease_renewals: [renewal]}} =
                 AssignmentManager.heartbeat(context.worker.id, context.session.id, %{"active_leases" => [assignment.id]}, context.manager)

        assert renewal.lease_id == assignment.id

        assert {:error, :lease_not_active} =
                 AssignmentManager.record_event(context.worker.id, context.session.id, "stale", "task.progress", %{}, context.manager)
      end

      test "cancel current reports cancelled only after worker terminal cancellation", context do
        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        cancellation = Task.async(fn -> AssignmentManager.cancel_current("operator", context.manager) end)
        assert Task.yield(cancellation, 20) == nil

        assert {:ok,
                %{
                  lease_renewals: [],
                  commands: [%{"type" => "cancel_task", "task_id" => task_id, "reason" => "operator"}]
                }} =
                 AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )

        assert task_id == assignment.id
        assert FakePersistence.get_run(assignment.run_id).status == "running"

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.cancelled",
                   %{"correlation" => assignment.correlation, "summary" => summary("cancelled")},
                   context.manager
                 )

        assert %{
                 status: "cancelled",
                 cancelled: 1,
                 failed: [],
                 project_id: nil,
                 tasks: [%{assignment_id: assignment_id, run_id: run_id}]
               } = Task.await(cancellation)

        assert assignment_id == assignment.id
        assert run_id == assignment.run_id
        assert AssignmentManager.current_assignment(context.manager) == nil
        assert FakePersistence.get_run(assignment.run_id).status == "cancelled"
        assert [_event] = FakePersistence.list_events(run_id: assignment.run_id, event_type: "task.cancelled")
      end

      test "cancel current distinguishes no active assignment and project mismatch", context do
        assert %{status: "no_active_assignment", cancelled: 0, failed: [], project_id: nil, tasks: []} =
                 AssignmentManager.cancel_current("operator", context.manager)

        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        assert %{status: "no_active_assignment", cancelled: 0, failed: [], project_id: "other-project", tasks: []} =
                 AssignmentManager.cancel_current("operator", "other-project", context.manager)

        assert {:ok, %{lease_renewals: [_renewal], commands: []}} =
                 AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )
      end

      test "cancel current reports failed when terminal cancellation persistence fails", context do
        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        :sys.replace_state(context.manager, &%{&1 | persistence: FailingCancelPersistence})

        cancellation = Task.async(fn -> AssignmentManager.cancel_current("operator", context.manager) end)
        assert Task.yield(cancellation, 20) == nil

        assert {:ok, %{lease_renewals: [], commands: [%{"type" => "cancel_task"}]}} =
                 AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )

        assert {:error, {:event_write_failed, :repo_unavailable}} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.cancelled",
                   %{"correlation" => assignment.correlation, "summary" => summary("cancelled")},
                   context.manager
                 )

        assert %{
                 status: "failed",
                 cancelled: 0,
                 failed: [%{assignment_id: assignment_id, reason: reason}],
                 project_id: nil,
                 tasks: []
               } = Task.await(cancellation)

        assert assignment_id == assignment.id
        assert reason =~ "terminal_event_failed"
        assert reason =~ "repo_unavailable"
        assert AssignmentManager.current_assignment(context.manager).id == assignment.id
      end

      test "idle heartbeat is not queued behind blocking reconciliation", context do
        Application.put_env(:symphony_elixir, :assignment_test_owner, self())

        name = Module.concat(__MODULE__, "BlockingReconcile#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(%{
            id: name,
            start:
              {AssignmentManager, :start_link,
               [
                 [
                   name: name,
                   tracker: BlockingReconcileTracker,
                   persistence: FakePersistence,
                   workflows: Workflows,
                   now: fn -> context.now end,
                   failure_circuit: context.circuit,
                   reconcile_interval_ms: :timer.hours(1)
                 ]
               ]}
          })

        AssignmentManager.reconcile(manager)
        assert_receive {:reconcile_blocked, blocked_pid}, 500

        calls_before = FakePersistence.calls()

        heartbeat =
          Task.async(fn ->
            for _ <- 1..3 do
              AssignmentManager.heartbeat(
                context.worker.id,
                context.session.id,
                %{"active_leases" => []},
                manager,
                FakePersistence
              )
            end
          end)

        assert {:ok, heartbeats} = Task.yield(heartbeat, 500)
        assert Enum.all?(heartbeats, &match?({:ok, %{lease_renewals: [], commands: []}}, &1))

        assert Enum.all?(FakePersistence.calls() -- calls_before, fn
                 {:heartbeat_worker, _worker_id, _session_id} -> false
                 _call -> true
               end)

        send(blocked_pid, :release_reconcile)
      end

      test "blocked reconciliation leaves active heartbeat and audit ingestion responsive", context do
        Application.put_env(:symphony_elixir, :assignment_test_owner, self())
        name = Module.concat(__MODULE__, "SlowReconcile#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(%{
            id: name,
            start:
              {AssignmentManager, :start_link,
               [
                 [
                   name: name,
                   tracker: SlowReconcileTracker,
                   persistence: FakePersistence,
                   workflows: Workflows,
                   now: fn -> context.now end,
                   failure_circuit: context.circuit,
                   reconcile_interval_ms: :timer.hours(1)
                 ]
               ]}
          })

        :ok = AssignmentManager.observe_session(context.worker, context.session, manager)
        Tracker.put([issue(1)])

        assert {:ok, assignment} =
                 AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   manager
                 )

        AssignmentManager.reconcile(manager)
        assert_receive {:slow_reconcile_started, reconcile}, 500

        assert {:ok, %{lease_renewals: [%{lease_id: lease_id}]}} =
                 AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   manager,
                   FakePersistence
                 )

        assert lease_id == assignment.id

        assert {:ok, event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "linear.tool_call",
                   %{"correlation" => assignment.correlation, "tool" => "linear_task_read", "status" => "success"},
                   manager
                 )

        assert event.event_type == "linear.tool_call"
        send(reconcile, :release_reconcile)
        assert_receive :slow_reconcile_finished
        assert FakePersistence.get_run(assignment.run_id).status == "running"
        assert FakePersistence.list_events(run_id: assignment.run_id, event_type: "task.failed") == []
      end

      test "reconciliation fetches once per distinct project slug", context do
        start_supervised!(ProjectTracker)
        workflow = Application.fetch_env!(:symphony_elixir, :assignment_test_workflow)
        other = put_in(workflow.config["tracker"]["project_slug"], "other-project")
        Application.put_env(:symphony_elixir, :assignment_test_workflows, [workflow, workflow, other])
        ProjectTracker.put(%{})
        name = Module.concat(__MODULE__, "DistinctReconcile#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(%{
            id: name,
            start:
              {AssignmentManager, :start_link,
               [
                 [
                   name: name,
                   tracker: ProjectTracker,
                   persistence: FakePersistence,
                   workflows: ConfiguredWorkflows,
                   now: fn -> context.now end,
                   failure_circuit: context.circuit,
                   reconcile_interval_ms: :timer.hours(1)
                 ]
               ]}
          })

        AssignmentManager.reconcile(manager)
        eventually(fn -> length(ProjectTracker.reconcile_fetches()) == 2 end)
        assert ProjectTracker.reconcile_fetches() == [get_in(workflow.config, ["tracker", "project_slug"]), "other-project"]
      end

      test "reconciliation timeout terminates the round before another round starts", context do
        Application.put_env(:symphony_elixir, :assignment_test_owner, self())
        name = Module.concat(__MODULE__, "TimedReconcile#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(%{
            id: name,
            start:
              {AssignmentManager, :start_link,
               [
                 [
                   name: name,
                   tracker: BlockingReconcileTracker,
                   persistence: FakePersistence,
                   workflows: Workflows,
                   now: fn -> context.now end,
                   failure_circuit: context.circuit,
                   tracker_io_timeout_ms: 50,
                   reconcile_interval_ms: :timer.hours(1)
                 ]
               ]}
          })

        log =
          capture_log(fn ->
            AssignmentManager.reconcile(manager)
            assert_receive {:reconcile_blocked, first_pid}, 500
            GenServer.cast(manager, {:reconcile_result, make_ref(), []})
            AssignmentManager.reconcile(manager)
            refute_receive {:reconcile_blocked, _pid}, 20
            eventually(fn -> not Process.alive?(first_pid) end)
            AssignmentManager.reconcile(manager)
            assert_receive {:reconcile_blocked, second_pid}, 500
            assert second_pid != first_pid
            send(second_pid, :release_reconcile)
          end)

        assert log =~ "event=worker_reconcile_tracker_timeout"
      end

      test "claim preparation timeout names its stage without occupying the manager mailbox", context do
        Application.put_env(:symphony_elixir, :assignment_test_owner, self())

        Application.put_env(:symphony_elixir, :assignment_test_fetch_hook, fn ->
          send(Application.fetch_env!(:symphony_elixir, :assignment_test_owner), {:claim_fetch_blocked, self()})

          receive do
            :release_claim_fetch -> :ok
          end
        end)

        name = Module.concat(__MODULE__, "TimedClaim#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(%{
            id: name,
            start:
              {AssignmentManager, :start_link,
               [
                 [
                   name: name,
                   tracker: Tracker,
                   persistence: FakePersistence,
                   workflows: Workflows,
                   now: fn -> context.now end,
                   failure_circuit: context.circuit,
                   tracker_io_timeout_ms: 50,
                   reconcile_interval_ms: :timer.hours(1)
                 ]
               ]}
          })

        :ok = AssignmentManager.observe_session(context.worker, context.session, manager)

        claim =
          Task.async(fn ->
            AssignmentManager.claim_with_policy(
              context.worker.id,
              context.session.id,
              %{"available_slots" => 1},
              :listening_all,
              1,
              manager
            )
          end)

        assert_receive {:claim_fetch_blocked, blocked_pid}, 500
        assert AssignmentManager.available_worker_slots(manager) == 1
        assert {:error, {:claim_prepare_timeout, :candidate_fetch}, 30} = Task.await(claim, 500)
        eventually(fn -> not Process.alive?(blocked_pid) end)
      end

      test "zombie reconciliation uses run lease without expiring worker sessions", context do
        ready = issue(1)
        Tracker.put([ready])
        assert {:ok, assignment} = claim(context)
        stop_supervised!(AssignmentManager)

        run = FakePersistence.get_run(assignment.run_id)
        {:ok, _} = FakePersistence.update_run(run, %{started_at: DateTime.add(context.now, -61, :second)})

        name = Module.concat(__MODULE__, "ZombieLease#{System.unique_integer([:positive])}")

        {:ok, restarted} =
          AssignmentManager.start_link(
            name: name,
            tracker: Tracker,
            persistence: ZombieReconcilePersistence,
            workflows: Workflows,
            now: fn -> context.now end,
            failure_circuit: context.circuit,
            reconcile_interval_ms: :timer.hours(1)
          )

        AssignmentManager.reconcile(restarted)
        eventually(fn -> length(FakePersistence.list_events(run_id: assignment.run_id, event_type: "run.orphaned")) == 1 end)
        assert Tracker.updates() == [{ready.id, "In Progress"}]
        assert FakePersistence.get_run(assignment.run_id).status == "running"
      end

      test "blocked heartbeat history does not delay matching lease renewal", context do
        Application.put_env(:symphony_elixir, :assignment_test_owner, self())

        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        Application.put_env(:symphony_elixir, :assignment_test_heartbeat_mode, :blocked)

        assert {:ok, %{lease_renewals: [renewal]}} =
                 AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager,
                   BlockingHeartbeatPersistence
                 )

        assert renewal.lease_id == assignment.id
        refute_receive {:heartbeat_blocked, _blocked_pid}, 50

        assert {:ok, %{lease_renewals: []}} =
                 AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => ["wrong"]},
                   context.manager,
                   BlockingHeartbeatPersistence
                 )
      end

      test "persists Linear audit events without releasing the assignment", context do
        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        assert {:ok, event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "linear.tool_call",
                   %{"correlation" => assignment.correlation, "tool" => "linear_task_read", "status" => "success"},
                   context.manager
                 )

        assert event.event_type == "linear.tool_call"
        assert event.payload["tool"] == "linear_task_read"
        assert event.payload["correlation"] == assignment.correlation
        assert AssignmentManager.current_assignment(context.manager).id == assignment.id
      end

      test "rejects unavailable sessions, zero slots, and mismatched correlation", context do
        Tracker.put([issue(1)])

        assert {:ok, {:empty, 5}} =
                 AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 0},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :no_available_slots}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 0},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_not_found}} =
                 AssignmentManager.claim_with_policy_evidence(
                   "wrong",
                   "wrong",
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert {:ok, %{lease_renewals: []}} = AssignmentManager.heartbeat("wrong", "wrong", %{}, context.manager)
        assert {:ok, assignment} = claim(context)

        assert {:error, {:correlation_mismatch, "run_id"}} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{"correlation" => %{"run_id" => "wrong"}},
                   context.manager
                 )

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{"phase" => "codex"},
                   context.manager
                 )

        assert %{status: "cancelled"} = cancel_assignment(context, assignment)
        assert AssignmentManager.current_assignment(context.manager) == nil

        assert %{status: "no_active_assignment"} = AssignmentManager.cancel_current("operator", context.manager)
      end

      test "stale persisted heartbeat state does not block fresh memory admission", context do
        Tracker.put([issue(1)])

        Agent.update(FakePersistence, fn state ->
          update_in(state.worker_sessions, fn sessions ->
            Enum.map(sessions, &%{&1 | last_heartbeat_at: DateTime.add(context.now, -31, :second), status: "offline"})
          end)
        end)

        assert {:ok, assignment, %{capacity: 1, reason: :assigned}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 4},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert assignment.worker_id == context.worker.id
        assert assignment.session_id == context.session.id
        refute old_freshness_predicate_called?()
      end

      test "expired memory liveness has zero capacity and rejects claim before tracker reads", context do
        Tracker.put([issue(1)])
        expire_worker_liveness(context)
        fetch_count = Tracker.fetch_count()

        assert AssignmentManager.available_worker_slots(context.manager) == 0

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_stale}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 4},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert Tracker.fetch_count() == fetch_count
        refute old_freshness_predicate_called?()

        assert {:ok, assignment, %{capacity: 1, reason: :assigned}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 4},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert assignment.issue_identifier == "SYM-1"
      end

      test "task events refresh liveness for the current memory assignment", context do
        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)
        expire_worker_liveness(context)

        assert AssignmentManager.available_worker_slots(context.manager) == 0

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{"correlation" => assignment.correlation, "phase" => "codex"},
                   context.manager
                 )

        assert AssignmentManager.available_worker_slots(context.manager) == 1
      end

      test "one assignment consumes capacity across sessions and advertised slot totals", context do
        Tracker.put([issue(1)])
        {:ok, other} = FakePersistence.register_worker(%{"worker_name" => "other", "total_slots" => 8})
        :ok = AssignmentManager.observe_session(other.worker, other.session, context.manager)
        assert {:ok, first} = claim(context)

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :active_assignment}} =
                 AssignmentManager.claim_with_policy_evidence(
                   other.worker.id,
                   other.session.id,
                   %{"available_slots" => 8},
                   :listening_all,
                   1,
                   context.manager
                 )

        complete(context, first)
        Tracker.put([issue(2)])

        assert {:ok, second, %{capacity: 1, reason: :assigned}} =
                 AssignmentManager.claim_with_policy_evidence(
                   other.worker.id,
                   other.session.id,
                   %{"available_slots" => 8},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert second.id != first.id
        assert second.run_id != first.run_id
      end

      test "public API is safe while worker dispatch is disabled", context do
        stop_supervised!(AssignmentManager)
        server = Module.concat(__MODULE__, :DisabledDispatch)

        assert {:ok, {:empty, 5}} =
                 AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{},
                   :listening_all,
                   1,
                   server
                 )

        assert {:ok, %{lease_renewals: [], commands: []}} =
                 AssignmentManager.heartbeat(context.worker.id, context.session.id, %{}, server)

        assert {:error, :lease_not_active} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   "gone",
                   "task.progress",
                   %{},
                   server
                 )

        assert AssignmentManager.current_assignment(server) == nil
        assert %{status: "no_active_assignment"} = AssignmentManager.cancel_current("disabled", server)
      end

      test "restart reconciliation preserves runs and emits one orphan signal after the lease window", context do
        ready = issue(1)
        Tracker.put([ready])
        assert {:ok, assignment} = claim(context)
        stop_supervised!(AssignmentManager)

        name = Module.concat(__MODULE__, "Restarted#{System.unique_integer([:positive])}")

        {:ok, restarted} =
          AssignmentManager.start_link(
            name: name,
            tracker: Tracker,
            persistence: FakePersistence,
            workflows: Workflows,
            now: fn -> context.now end,
            failure_circuit: context.circuit,
            reconcile_interval_ms: :timer.hours(1)
          )

        assert AssignmentManager.current_assignment(restarted) == nil
        AssignmentManager.reconcile(restarted)
        eventually(fn -> :sys.get_state(restarted).reconcile_task == nil end)
        assert Tracker.updates() == [{ready.id, "In Progress"}]

        run = FakePersistence.get_run(assignment.run_id)
        {:ok, _} = FakePersistence.update_run(run, %{started_at: DateTime.add(context.now, -61, :second)})
        AssignmentManager.reconcile(restarted)
        eventually(fn -> length(FakePersistence.list_events(run_id: assignment.run_id, event_type: "run.orphaned")) == 1 end)
        AssignmentManager.reconcile(restarted)
        eventually(fn -> :sys.get_state(restarted).reconcile_task == nil end)
        assert Tracker.updates() == [{ready.id, "In Progress"}]
        assert FakePersistence.get_run(assignment.run_id).status == "running"
        assert length(FakePersistence.list_events(run_id: assignment.run_id, event_type: "run.orphaned")) == 1

        assert {:error, :lease_not_active} =
                 AssignmentManager.record_event(context.worker.id, context.session.id, assignment.id, "task.completed", %{}, restarted)
      end
    end
  end
end

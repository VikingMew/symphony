# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Worker.AssignmentManagerTest.Sections.AssignmentManager2 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import ExUnit.CaptureLog

      alias SymphonyElixir.BlockingDecision
      alias SymphonyElixir.Config.WorkflowScopes
      alias SymphonyElixir.EnvironmentFailureCircuit
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.Orchestrator.Events
      alias SymphonyElixir.TestSupport.FakePersistence
      alias SymphonyElixir.Worker.AssignmentManager
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixirWeb.Presenter

      import ExUnit.CaptureLog
      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Health
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.TestSupport.FakePersistence
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Worker.HeartbeatMetrics
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          ensure_panel_children_running!: 0,
          panel_supervisor_running?: 0,
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      alias SymphonyElixir.Worker.AssignmentManagerTest.{
        BlockingHeartbeatPersistence,
        BlockingReconcileTracker,
        FailingCancelPersistence,
        ProjectTracker,
        Tracker,
        Workflows,
        ZombieReconcilePersistence
      }

      test "claims Ready implementation issues into In Progress and returns implementation payload state",
           context do
        ready = issue(3)
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([ready])

        assert {:ok, assignment} = claim(context)

        assert Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.updates() == [
                 {ready.id, "In Progress"}
               ]

        assert assignment.issue.state == "In Progress"
        assert assignment.payload["issue"]["state"] == "In Progress"
        assert assignment.payload["workflow_profile"] == "implementation"

        assert assignment.payload["handoff"]["allowed_updates"]["target_states"] == [
                 "In Progress",
                 "Ready to Merge"
               ]

        assert assignment.payload["prompt"] =~ "Current status: In Progress"
        assert assignment.payload["prompt"] =~ "Ready to Merge"
      end

      test "fails Todo refinement claim visibly when Linear rejects Refining transition", context do
        todo = %{issue(4) | state: "Todo"}
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([todo])
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.fail_update(:transition_rejected)

        assert {:error, :transition_rejected} = claim(context)
        assert Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.updates() == []

        assert [%{status: "failed"}] =
                 Elixir.SymphonyElixir.TestSupport.FakePersistence.list_runs_for_issue(todo.identifier)

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.current_assignment(context.manager) == nil
      end

      test "Refining latest running worker run blocks duplicate assignment", context do
        enable_active_state("Refining")
        refining = %{issue(5) | state: "Refining"}
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([refining])

        {:ok, _run} =
          Elixir.SymphonyElixir.TestSupport.FakePersistence.create_run(%{
            issue_identifier: refining.identifier,
            status: "running",
            started_at: context.now
          })

        assert {:ok, {:empty, 5}} = claim(context)
        assert Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.updates() == []
      end

      test "Refining latest terminal worker run can be assigned without another state update",
           context do
        enable_active_state("Refining")
        refining = %{issue(6) | state: "Refining"}
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([refining])

        {:ok, _run} =
          Elixir.SymphonyElixir.TestSupport.FakePersistence.create_run(%{
            issue_identifier: refining.identifier,
            status: "succeeded",
            started_at: context.now
          })

        assert {:ok, assignment} = claim(context)

        assert assignment.issue.state == "Refining"
        assert assignment.payload["issue"]["state"] == "Refining"
        assert Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.updates() == []
      end

      test "failure ends the assignment and the next claim rereads Linear", context do
        ready = issue(1)
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([ready])
        assert {:ok, assignment} = claim(context)

        assert {:ok, _event} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.failed",
                   %{"correlation" => assignment.correlation, "summary" => summary("failed")},
                   context.manager
                 )

        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([])
        assert {:ok, {:empty, 5}} = claim(context)
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([ready])
        assert {:ok, next} = claim(context)
        assert next.id == assignment.id == false
        assert next.run_id == assignment.run_id == false
      end

      test "heartbeat renews only the owning assignment and stale events are rejected", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        assert {:ok, %{lease_renewals: []}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => ["wrong"]},
                   context.manager
                 )

        assert {:ok, %{lease_renewals: [renewal]}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )

        assert renewal.lease_id == assignment.id

        assert {:error, :lease_not_active} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   "stale",
                   "task.progress",
                   %{},
                   context.manager
                 )
      end

      test "cancel current reports cancelled only after worker terminal cancellation", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        cancellation =
          Task.async(fn ->
            Elixir.SymphonyElixir.Worker.AssignmentManager.cancel_current("operator", context.manager)
          end)

        assert Task.yield(cancellation, 20) == nil

        assert {:ok,
                %{
                  lease_renewals: [],
                  commands: [%{"type" => "cancel_task", "task_id" => task_id, "reason" => "operator"}]
                }} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )

        assert task_id == assignment.id

        assert Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id).status ==
                 "running"

        assert {:ok, _event} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
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
        assert Elixir.SymphonyElixir.Worker.AssignmentManager.current_assignment(context.manager) == nil

        assert Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id).status ==
                 "cancelled"

        assert [_event] =
                 Elixir.SymphonyElixir.TestSupport.FakePersistence.list_events(
                   run_id: assignment.run_id,
                   event_type: "task.cancelled"
                 )
      end

      test "cancel current distinguishes no active assignment and project mismatch", context do
        assert %{status: "no_active_assignment", cancelled: 0, failed: [], project_id: nil, tasks: []} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.cancel_current(
                   "operator",
                   context.manager
                 )

        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        assert %{
                 status: "no_active_assignment",
                 cancelled: 0,
                 failed: [],
                 project_id: "other-project",
                 tasks: []
               } =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.cancel_current(
                   "operator",
                   "other-project",
                   context.manager
                 )

        assert {:ok, %{lease_renewals: [_renewal], commands: []}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )
      end

      test "cancel current reports failed when terminal cancellation persistence fails", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        :sys.replace_state(
          context.manager,
          &%{
            &1
            | persistence: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.FailingCancelPersistence
          }
        )

        cancellation =
          Task.async(fn ->
            Elixir.SymphonyElixir.Worker.AssignmentManager.cancel_current("operator", context.manager)
          end)

        assert Task.yield(cancellation, 20) == nil

        assert {:ok, %{lease_renewals: [], commands: [%{"type" => "cancel_task"}]}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )

        assert {:error, :repo_unavailable} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
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

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.current_assignment(context.manager).id ==
                 assignment.id
      end

      test "idle heartbeat is not queued behind blocking reconciliation", context do
        Application.put_env(:symphony_elixir, :assignment_test_owner, self())

        name = Module.concat(__MODULE__, "BlockingReconcile#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(%{
            id: name,
            start:
              {Elixir.SymphonyElixir.Worker.AssignmentManager, :start_link,
               [
                 [
                   name: name,
                   tracker: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.BlockingReconcileTracker,
                   persistence: Elixir.SymphonyElixir.TestSupport.FakePersistence,
                   workflows: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Workflows,
                   now: fn -> context.now end,
                   failure_circuit: context.circuit,
                   reconcile_interval_ms: :timer.hours(1)
                 ]
               ]}
          })

        Elixir.SymphonyElixir.Worker.AssignmentManager.reconcile(manager)
        assert_receive {:reconcile_blocked, blocked_pid}, 500

        calls_before = Elixir.SymphonyElixir.TestSupport.FakePersistence.calls()

        heartbeat =
          Task.async(fn ->
            for _ <- 1..3 do
              Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                context.worker.id,
                context.session.id,
                %{"active_leases" => []},
                manager,
                Elixir.SymphonyElixir.TestSupport.FakePersistence
              )
            end
          end)

        assert {:ok, heartbeats} = Task.yield(heartbeat, 500)
        assert Enum.all?(heartbeats, &match?({:ok, %{lease_renewals: [], commands: []}}, &1))
        assert Elixir.SymphonyElixir.TestSupport.FakePersistence.calls() == calls_before

        send(blocked_pid, :release_reconcile)
      end

      test "zombie reconciliation uses run lease without expiring worker sessions", context do
        ready = issue(1)
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([ready])
        assert {:ok, assignment} = claim(context)
        Process.exit(context.manager, :normal)
        Process.sleep(10)

        run = Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id)

        {:ok, _} =
          Elixir.SymphonyElixir.TestSupport.FakePersistence.update_run(run, %{
            started_at: DateTime.add(context.now, -61, :second)
          })

        name = Module.concat(__MODULE__, "ZombieLease#{System.unique_integer([:positive])}")

        {:ok, restarted} =
          Elixir.SymphonyElixir.Worker.AssignmentManager.start_link(
            name: name,
            tracker: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker,
            persistence: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.ZombieReconcilePersistence,
            workflows: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Workflows,
            now: fn -> context.now end,
            failure_circuit: context.circuit,
            reconcile_interval_ms: :timer.hours(1)
          )

        Elixir.SymphonyElixir.Worker.AssignmentManager.reconcile(restarted)

        eventually(fn ->
          List.last(Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.updates()) ==
            {ready.id, "Ready"}
        end)

        assert Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id).status ==
                 "failed"
      end

      test "blocked heartbeat history does not delay matching lease renewal", context do
        Application.put_env(:symphony_elixir, :assignment_test_owner, self())

        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        Application.put_env(:symphony_elixir, :assignment_test_heartbeat_mode, :blocked)

        assert {:ok, %{lease_renewals: [renewal]}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager,
                   Elixir.SymphonyElixir.Worker.AssignmentManagerTest.BlockingHeartbeatPersistence
                 )

        assert renewal.lease_id == assignment.id
        refute_receive {:heartbeat_blocked, _blocked_pid}, 50

        assert {:ok, %{lease_renewals: []}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => ["wrong"]},
                   context.manager,
                   Elixir.SymphonyElixir.Worker.AssignmentManagerTest.BlockingHeartbeatPersistence
                 )
      end

      test "persists Linear audit events without releasing the assignment", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)

        assert {:ok, event} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "linear.tool_call",
                   %{
                     "correlation" => assignment.correlation,
                     "tool" => "linear_task_read",
                     "status" => "success"
                   },
                   context.manager
                 )

        assert event.event_type == "linear.tool_call"
        assert event.payload["tool"] == "linear_task_read"
        assert event.payload["correlation"] == assignment.correlation

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.current_assignment(context.manager).id ==
                 assignment.id
      end

      test "rejects unavailable sessions, zero slots, and mismatched correlation", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])

        assert {:ok, {:empty, 5}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 0},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :no_available_slots}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 0},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_not_found}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
                   "wrong",
                   "wrong",
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert {:ok, %{lease_renewals: []}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   "wrong",
                   "wrong",
                   %{},
                   context.manager
                 )

        assert {:ok, assignment} = claim(context)

        assert {:error, {:correlation_mismatch, "run_id"}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{"correlation" => %{"run_id" => "wrong"}},
                   context.manager
                 )

        assert {:ok, _event} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{"phase" => "codex"},
                   context.manager
                 )

        assert %{status: "cancelled"} = cancel_assignment(context, assignment)
        assert Elixir.SymphonyElixir.Worker.AssignmentManager.current_assignment(context.manager) == nil

        assert %{status: "no_active_assignment"} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.cancel_current(
                   "operator",
                   context.manager
                 )
      end

      test "stale persisted heartbeat state does not block fresh memory admission", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])

        Agent.update(Elixir.SymphonyElixir.TestSupport.FakePersistence, fn state ->
          update_in(state.worker_sessions, fn sessions ->
            Enum.map(
              sessions,
              &%{&1 | last_heartbeat_at: DateTime.add(context.now, -31, :second), status: "offline"}
            )
          end)
        end)

        assert {:ok, assignment, %{capacity: 1, reason: :assigned}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
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

      test "expired memory liveness has zero capacity and rejects claim before tracker reads",
           context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        expire_worker_liveness(context)
        fetch_count = Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.fetch_count()

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.available_worker_slots(context.manager) ==
                 0

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_stale}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 4},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.fetch_count() == fetch_count
        refute old_freshness_predicate_called?()

        assert {:ok, assignment, %{capacity: 1, reason: :assigned}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
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
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)
        expire_worker_liveness(context)

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.available_worker_slots(context.manager) ==
                 0

        assert {:ok, _event} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{"correlation" => assignment.correlation, "phase" => "codex"},
                   context.manager
                 )

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.available_worker_slots(context.manager) ==
                 1
      end

      test "one assignment consumes capacity across sessions and advertised slot totals", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])

        {:ok, other} =
          Elixir.SymphonyElixir.TestSupport.FakePersistence.register_worker(%{
            "worker_name" => "other",
            "total_slots" => 8
          })

        :ok =
          Elixir.SymphonyElixir.Worker.AssignmentManager.observe_session(
            other.worker,
            other.session,
            context.manager
          )

        assert {:ok, first} = claim(context)

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :active_assignment}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
                   other.worker.id,
                   other.session.id,
                   %{"available_slots" => 8},
                   :listening_all,
                   1,
                   context.manager
                 )

        complete(context, first)
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(2)])

        assert {:ok, second, %{capacity: 1, reason: :assigned}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
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

      test "expires an assignment before accepting a late event", context do
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)
        run = Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id)

        {:ok, _} =
          Elixir.SymphonyElixir.TestSupport.FakePersistence.update_run(run, %{
            started_at: DateTime.add(context.now, -61, :second)
          })

        :sys.replace_state(context.manager, fn state ->
          put_in(state.assignment.expires_at, DateTime.add(context.now, -1, :second))
        end)

        assert {:error, :lease_not_active} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{},
                   context.manager
                 )

        assert Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id).status ==
                 "failed"
      end

      test "public API is safe while worker dispatch is disabled", context do
        Process.exit(context.manager, :normal)
        Process.sleep(10)

        assert {:ok, {:empty, 5}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert {:ok, %{lease_renewals: [], commands: []}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{},
                   context.manager
                 )

        assert {:error, :lease_not_active} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   "gone",
                   "task.progress",
                   %{},
                   context.manager
                 )

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.current_assignment(context.manager) == nil

        assert %{status: "no_active_assignment"} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.cancel_current(
                   "disabled",
                   context.manager
                 )
      end

      test "restart reconciliation preserves a recent run and resets an expired zombie", context do
        ready = issue(1)
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([ready])
        assert {:ok, assignment} = claim(context)
        Process.exit(context.manager, :normal)
        Process.sleep(10)

        name = Module.concat(__MODULE__, "Restarted#{System.unique_integer([:positive])}")

        {:ok, restarted} =
          Elixir.SymphonyElixir.Worker.AssignmentManager.start_link(
            name: name,
            tracker: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker,
            persistence: Elixir.SymphonyElixir.TestSupport.FakePersistence,
            workflows: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Workflows,
            now: fn -> context.now end,
            failure_circuit: context.circuit,
            reconcile_interval_ms: :timer.hours(1)
          )

        assert Elixir.SymphonyElixir.Worker.AssignmentManager.current_assignment(restarted) == nil
        Elixir.SymphonyElixir.Worker.AssignmentManager.reconcile(restarted)
        Process.sleep(10)

        assert Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.updates() == [
                 {ready.id, "In Progress"}
               ]

        run = Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id)

        {:ok, _} =
          Elixir.SymphonyElixir.TestSupport.FakePersistence.update_run(run, %{
            started_at: DateTime.add(context.now, -61, :second)
          })

        Elixir.SymphonyElixir.Worker.AssignmentManager.reconcile(restarted)
        Process.sleep(10)

        assert List.last(Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.updates()) ==
                 {ready.id, "Ready"}

        assert Elixir.SymphonyElixir.TestSupport.FakePersistence.get_run(assignment.run_id).status ==
                 "failed"

        assert {:error, :lease_not_active} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.completed",
                   %{},
                   restarted
                 )
      end

      test "restart leaves worker liveness empty until a later live request records it", context do
        ready = issue(1)
        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([ready])
        assert {:ok, assignment} = claim(context)
        complete(context, assignment)
        Process.exit(context.manager, :normal)
        Process.sleep(10)

        name = Module.concat(__MODULE__, "RestartedLiveness#{System.unique_integer([:positive])}")

        {:ok, restarted} =
          Elixir.SymphonyElixir.Worker.AssignmentManager.start_link(
            name: name,
            tracker: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker,
            persistence: Elixir.SymphonyElixir.TestSupport.FakePersistence,
            workflows: Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Workflows,
            now: fn -> context.now end,
            failure_circuit: context.circuit,
            reconcile_interval_ms: :timer.hours(1)
          )

        Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.put([issue(2)])
        fetch_count = Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.fetch_count()
        assert Elixir.SymphonyElixir.Worker.AssignmentManager.available_worker_slots(restarted) == 0

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_not_found}} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   restarted
                 )

        assert Elixir.SymphonyElixir.Worker.AssignmentManagerTest.Tracker.fetch_count() == fetch_count
        assert Elixir.SymphonyElixir.Worker.AssignmentManager.available_worker_slots(restarted) == 1

        assert {:ok, next} =
                 Elixir.SymphonyElixir.Worker.AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   restarted
                 )

        assert next.issue_identifier == "SYM-2"
      end
    end
  end
end

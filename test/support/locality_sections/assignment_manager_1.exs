# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.AssignmentManager1 do
  @moduledoc false

  alias SymphonyElixir.BlockingDecision
  alias SymphonyElixir.EnvironmentFailureCircuit
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixir.Worker.AssignmentManagerTest.Tracker
  alias SymphonyElixir.Worker.AssignmentManagerTest.Workflows
  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.Presenter

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      use ExUnit.Case, async: false

      import ExUnit.CaptureLog

      defmodule Tracker do
        use Agent

        def start_link(_opts) do
          initial = %{candidates: [], current: %{}, updates: [], fetch_error: nil, update_error: nil, fetch_count: 0}
          Agent.start_link(fn -> initial end, name: __MODULE__)
        end

        def put(issues), do: Agent.update(__MODULE__, &%{&1 | candidates: issues, current: Map.new(issues, fn issue -> {issue.id, issue} end)})
        def replace(issue), do: Agent.update(__MODULE__, &put_in(&1.current[issue.id], issue))
        def fail_fetch(reason), do: Agent.update(__MODULE__, &%{&1 | fetch_error: reason})
        def fail_update(reason), do: Agent.update(__MODULE__, &%{&1 | update_error: reason})
        def updates, do: Agent.get(__MODULE__, &Enum.reverse(&1.updates))
        def fetch_count, do: Agent.get(__MODULE__, & &1.fetch_count)

        def fetch_candidate_issues do
          if hook = Application.get_env(:symphony_elixir, :assignment_test_fetch_hook) do
            hook.()
          end

          Agent.get_and_update(__MODULE__, fn
            %{fetch_error: nil, candidates: candidates} = state ->
              {{:ok, candidates}, %{state | fetch_count: state.fetch_count + 1}}

            %{fetch_error: reason} = state ->
              {{:error, reason}, %{state | fetch_count: state.fetch_count + 1}}
          end)
        end

        def fetch_issue_states_by_ids(ids) do
          if hook = Application.get_env(:symphony_elixir, :assignment_test_revalidate_hook) do
            hook.()
          end

          {:ok,
           Agent.get(__MODULE__, fn data ->
             ids |> Enum.map(&data.current[&1]) |> Enum.reject(&is_nil/1)
           end)}
        end

        def fetch_issues_by_states(states), do: {:ok, Agent.get(__MODULE__, &(&1.current |> Map.values() |> Enum.filter(fn issue -> issue.state in states end)))}

        def update_issue_state(id, state) do
          Agent.get_and_update(__MODULE__, fn
            %{update_error: nil} = data ->
              current = Map.update!(data.current, id, &%{&1 | state: state})
              {:ok, %{data | current: current, updates: [{id, state} | data.updates]}}

            %{update_error: reason} = data ->
              {{:error, reason}, data}
          end)
        end
      end

      defmodule Workflows do
        def list_enabled do
          workflow = Application.fetch_env!(:symphony_elixir, :assignment_test_workflow)
          List.duplicate(workflow, Application.get_env(:symphony_elixir, :assignment_test_workflow_count, 1))
        end
      end

      defmodule ProjectTracker do
        use Agent

        def start_link(_opts) do
          Agent.start_link(fn -> %{candidates: %{}, current: %{}, fetches: [], reconcile_fetches: [], updates: []} end,
            name: __MODULE__
          )
        end

        def put(candidates_by_slug) do
          current =
            candidates_by_slug
            |> Map.values()
            |> List.flatten()
            |> Map.new(fn issue -> {issue.id, issue} end)

          Agent.update(__MODULE__, &%{&1 | candidates: candidates_by_slug, current: current})
        end

        def fetches, do: Agent.get(__MODULE__, & &1.fetches)
        def reconcile_fetches, do: Agent.get(__MODULE__, & &1.reconcile_fetches)

        def fetch_candidate_issues do
          slug = SymphonyElixir.Config.settings!().tracker.project_slug

          Agent.get_and_update(__MODULE__, fn state ->
            {{:ok, Map.get(state.candidates, slug, [])}, %{state | fetches: state.fetches ++ [slug]}}
          end)
        end

        def fetch_issue_states_by_ids(ids) do
          {:ok,
           Agent.get(__MODULE__, fn data ->
             ids |> Enum.map(&data.current[&1]) |> Enum.reject(&is_nil/1)
           end)}
        end

        def fetch_issues_by_states(states) do
          slug = SymphonyElixir.Config.settings!().tracker.project_slug

          Agent.get_and_update(__MODULE__, fn state ->
            issues = state.current |> Map.values() |> Enum.filter(fn issue -> issue.state in states end)
            {{:ok, issues}, %{state | reconcile_fetches: state.reconcile_fetches ++ [slug]}}
          end)
        end

        def update_issue_state(id, state) do
          Agent.update(__MODULE__, fn data ->
            current = Map.update!(data.current, id, &%{&1 | state: state})
            %{data | current: current, updates: [{id, state} | data.updates]}
          end)

          :ok
        end
      end

      defmodule BlockingReconcileTracker do
        def fetch_issues_by_states(_states) do
          send(Application.fetch_env!(:symphony_elixir, :assignment_test_owner), {:reconcile_blocked, self()})

          receive do
            :release_reconcile -> {:ok, []}
          end
        end
      end

      defmodule SlowReconcileTracker do
        defdelegate fetch_candidate_issues(), to: Tracker
        defdelegate fetch_issue_states_by_ids(ids), to: Tracker
        defdelegate update_issue_state(id, state), to: Tracker

        def fetch_issues_by_states(states) do
          owner = Application.fetch_env!(:symphony_elixir, :assignment_test_owner)
          send(owner, {:slow_reconcile_started, self()})

          receive do
            :release_reconcile -> :ok
          end

          result = Tracker.fetch_issues_by_states(states)
          send(owner, :slow_reconcile_finished)
          result
        end
      end

      defmodule ConfiguredWorkflows do
        def list_enabled, do: Application.fetch_env!(:symphony_elixir, :assignment_test_workflows)
      end

      defmodule ZombieReconcilePersistence do
        defdelegate list_runs_for_issue(identifier, opts), to: FakePersistence
        defdelegate list_events(opts), to: FakePersistence
        defdelegate record_event(attrs), to: FakePersistence
        defdelegate worker_heartbeat_interval_seconds(), to: FakePersistence
        defdelegate worker_lease_duration_seconds(), to: FakePersistence
        defdelegate worker_session_identity(worker_id, session_id), to: FakePersistence

        def expire_stale_worker_sessions(_opts \\ []), do: raise("zombie reconciliation must not expire worker sessions")
      end

      defmodule BlockingHeartbeatPersistence do
        defdelegate active_worker_session(worker_id, session_id), to: FakePersistence
        defdelegate expire_stale_worker_sessions(opts \\ []), to: FakePersistence
        defdelegate worker_heartbeat_interval_seconds(), to: FakePersistence
        defdelegate worker_lease_duration_seconds(), to: FakePersistence
        defdelegate worker_session_identity(worker_id, session_id), to: FakePersistence

        def heartbeat_worker(worker_id, session_id) do
          case Application.get_env(:symphony_elixir, :assignment_test_heartbeat_mode, :fast) do
            :blocked ->
              send(Application.fetch_env!(:symphony_elixir, :assignment_test_owner), {:heartbeat_blocked, self()})

              receive do
                :release_heartbeat -> FakePersistence.heartbeat_worker(worker_id, session_id)
              end

            :fast ->
              FakePersistence.heartbeat_worker(worker_id, session_id)
          end
        end
      end

      defmodule FailingCancelPersistence do
        defdelegate get_event(id), to: FakePersistence
        defdelegate worker_event_transaction(fun), to: FakePersistence
        defdelegate get_run(id), to: FakePersistence
        defdelegate update_run(run, attrs), to: FakePersistence
        defdelegate worker_lease_duration_seconds(), to: FakePersistence

        def record_event(%{event_type: "task.cancelled"}), do: {:error, :repo_unavailable}
        def record_event(attrs), do: FakePersistence.record_event(attrs)
      end

      setup do
        previous_execution_mode = Application.get_env(:symphony_elixir, :execution_mode)
        Application.put_env(:symphony_elixir, :execution_mode, :worker)
        FakePersistence.reset!()
        start_supervised!(Tracker)
        circuit = Module.concat(__MODULE__, "Circuit#{System.unique_integer([:positive])}")
        start_supervised!({EnvironmentFailureCircuit, name: circuit})
        {:ok, loaded} = Workflow.load_example_package()
        workflow = Map.put(loaded, :project_id, "fake-project-id")
        Application.put_env(:symphony_elixir, :assignment_test_workflow, workflow)
        {:ok, registration} = FakePersistence.register_worker(%{"worker_name" => "test", "total_slots" => 1})
        now = DateTime.utc_now()
        name = Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")

        pid =
          start_supervised!(
            {AssignmentManager, name: name, tracker: Tracker, persistence: FakePersistence, workflows: Workflows, now: fn -> now end, failure_circuit: circuit, reconcile_interval_ms: :timer.hours(1)}
          )

        :ok = AssignmentManager.observe_session(registration.worker, registration.session, pid)

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :assignment_test_workflow)
          Application.delete_env(:symphony_elixir, :assignment_test_workflow_count)
          Application.delete_env(:symphony_elixir, :assignment_test_owner)
          Application.delete_env(:symphony_elixir, :assignment_test_workflows)
          Application.delete_env(:symphony_elixir, :assignment_test_heartbeat_mode)
          Application.delete_env(:symphony_elixir, :assignment_test_revalidate_hook)
          Application.delete_env(:symphony_elixir, :assignment_test_fetch_hook)
          Application.delete_env(:symphony_elixir, :blocking_decision_cas_hook)
          Application.delete_env(:symphony_elixir, :fake_admit_run_hook)

          if is_nil(previous_execution_mode),
            do: Application.delete_env(:symphony_elixir, :execution_mode),
            else: Application.put_env(:symphony_elixir, :execution_mode, previous_execution_mode)
        end)

        %{manager: pid, worker: registration.worker, session: registration.session, now: now, circuit: circuit}
      end

      test "serializes live claims and creates a fresh assignment after completion", context do
        issues = for number <- 1..12, do: issue(number)
        Tracker.put(issues)

        first_claim = Task.async(fn -> claim(context) end)
        second_claim = Task.async(fn -> claim(context) end)
        results = Enum.map([first_claim, second_claim], &Task.await/1)
        assigned = for {:ok, %{} = assignment} <- results, do: assignment
        assert length(Enum.uniq_by(assigned, & &1.id)) == 1
        assert Enum.all?(results, &(match?({:ok, %{}}, &1) or &1 == {:ok, {:empty, 5}}))

        {:ok, first} = Enum.find(results, &match?({:ok, %{}}, &1))
        complete(context, first)
        Tracker.put(tl(issues))

        identifiers =
          Enum.reduce(2..12, [first.issue_identifier], fn number, claimed ->
            {:ok, assignment} = claim(context)
            complete(context, assignment)
            Tracker.put(Enum.drop(issues, number))
            [assignment.issue_identifier | claimed]
          end)

        assert length(Enum.uniq(identifiers)) == 12
        assert AssignmentManager.current_assignment(context.manager) == nil
      end

      test "not-listening worker claim returns evidence before tracker or persistence side effects", context do
        orchestrator = start_orchestrator()
        manager = start_manager(context, orchestrator, context.now)
        Tracker.put([issue(1)])
        fetch_count = Tracker.fetch_count()

        log =
          capture_log(fn ->
            assert {:ok, {:empty, 5}, evidence} =
                     Orchestrator.claim_worker(
                       context.worker.id,
                       context.session.id,
                       %{"available_slots" => 1},
                       orchestrator,
                       manager
                     )

            assert evidence == %{capacity: 0, reason: :not_listening, listening_mode: :not_listening}
          end)

        assert log =~ "event=worker_claim_skip"
        assert log =~ "worker_id=#{context.worker.id}"
        assert log =~ "session_id=#{context.session.id}"
        assert log =~ "skip_reason=not_listening"
        assert log =~ "listening_mode=not_listening"
        assert log =~ "capacity=0"
        assert Tracker.fetch_count() == fetch_count
        assert FakePersistence.list_runs_for_issue("SYM-1") == []
        assert FakePersistence.list_events(event_type: "task.accepted") == []
        assert Tracker.updates() == []
      end

      test "refine-only claim skips an earlier implementation candidate and assigns refinement", context do
        orchestrator = start_orchestrator()
        manager = start_manager(context, orchestrator, context.now)
        ready = issue(1)
        todo = %{issue(2) | state: "Todo"}
        Tracker.put([ready, todo])
        set_listening_mode(orchestrator, :listening_refine_only)

        assert {:ok, assignment, %{capacity: 1, reason: :assigned, listening_mode: :listening_refine_only}} =
                 Orchestrator.claim_worker(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   orchestrator,
                   manager
                 )

        assert assignment.issue_identifier == todo.identifier
        assert Tracker.updates() == [{todo.id, "Refining"}]
        assert FakePersistence.list_runs_for_issue(ready.identifier) == []
      end

      test "refine-only claim returns filtering evidence when only implementation is eligible", context do
        orchestrator = start_orchestrator()
        manager = start_manager(context, orchestrator, context.now)
        ready = issue(1)
        Tracker.put([ready])
        set_listening_mode(orchestrator, :listening_refine_only)

        log =
          capture_log(fn ->
            assert {:ok, {:empty, 5}, evidence} =
                     Orchestrator.claim_worker(
                       context.worker.id,
                       context.session.id,
                       %{"available_slots" => 1},
                       orchestrator,
                       manager
                     )

            assert evidence == %{capacity: 0, reason: :listening_mode, listening_mode: :listening_refine_only}
          end)

        assert log =~ "skip_reason=listening_mode"
        assert log =~ "listening_mode=listening_refine_only"
        assert FakePersistence.list_runs_for_issue(ready.identifier) == []
        assert Tracker.updates() == []
      end

      test "stop-listening waits for an in-flight claim and gates every later claim", context do
        orchestrator = start_orchestrator()
        manager = start_manager(context, orchestrator, context.now)
        ready = issue(1)
        Tracker.put([ready])
        set_listening_mode(orchestrator, :listening_all)
        owner = self()

        Application.put_env(:symphony_elixir, :assignment_test_fetch_hook, fn ->
          send(owner, {:claim_fetch_started, self()})

          receive do
            :release_claim_fetch -> :ok
          end
        end)

        claim_task =
          Task.async(fn ->
            Orchestrator.claim_worker(
              context.worker.id,
              context.session.id,
              %{"available_slots" => 1},
              orchestrator,
              manager
            )
          end)

        assert_receive {:claim_fetch_started, claim_process}
        stop_task = Task.async(fn -> Orchestrator.stop_listening(orchestrator) end)
        assert Task.yield(stop_task, 20) == nil
        send(claim_process, :release_claim_fetch)

        assert {:ok, assignment, %{reason: :assigned, listening_mode: :listening_all}} = Task.await(claim_task)
        assert %{listening?: false, listening_mode: "not_listening"} = Task.await(stop_task)
        assert AssignmentManager.current_assignment(manager).id == assignment.id

        Application.delete_env(:symphony_elixir, :assignment_test_fetch_hook)
        complete_with_manager(context, assignment, manager)
        Tracker.put([issue(2)])
        fetch_count = Tracker.fetch_count()

        assert {:ok, {:empty, 5}, %{reason: :not_listening, listening_mode: :not_listening}} =
                 Orchestrator.claim_worker(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   orchestrator,
                   manager
                 )

        assert Tracker.fetch_count() == fetch_count
        assert FakePersistence.list_runs_for_issue("SYM-2") == []
      end

      test "accepted worker assignment feeds current state until terminal completion", context do
        orchestrator = start_orchestrator()
        manager = start_manager(context, orchestrator, DateTime.add(DateTime.utc_now(), -5, :second))
        ready = issue(99)
        Tracker.put([ready])

        assert {:ok, assignment} =
                 AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   manager
                 )

        eventually(fn ->
          payload = Presenter.state_payload(orchestrator, 100)

          payload.counts.running == 1 and
            match?(
              [
                %{
                  issue_id: "issue-99",
                  issue_identifier: "SYM-99",
                  run_id: run_id,
                  started_at: started_at,
                  runtime_seconds: runtime_seconds
                }
              ]
              when run_id == assignment.run_id and is_binary(started_at) and runtime_seconds > 0,
              payload.running
            )
        end)

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{
                     "correlation" => assignment.correlation,
                     "phase" => "codex_session_started",
                     "session_id" => "codex-worker-session"
                   },
                   manager
                 )

        eventually(fn ->
          match?([%{session_id: "codex-worker-session"}], Presenter.state_payload(orchestrator, 100).running)
        end)

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{
                     "correlation" => assignment.correlation,
                     "phase" => "source_preparation",
                     "source" => "worker",
                     "operation" => "git_fetch",
                     "status" => "output",
                     "detail" => "Receiving objects: 50%"
                   },
                   manager
                 )

        eventually(fn ->
          %{running: [running]} = Orchestrator.snapshot(orchestrator, 100)

          Enum.any?(running.session_history, fn event ->
            event.event == :system_progress and event.source == "worker" and
              event.metadata.phase == "source_preparation" and event.metadata.operation == "git_fetch" and
              event.detail == "Receiving objects: 50%"
          end)
        end)

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.completed",
                   %{"correlation" => assignment.correlation, "summary" => summary("succeeded")},
                   manager
                 )

        eventually(fn ->
          payload = Presenter.state_payload(orchestrator, 100)
          payload.counts.running == 0 and payload.running == [] and payload.codex_totals.seconds_running > 0
        end)
      end

      test "worker codex progress applies absolute token deltas to current state", context do
        orchestrator = start_orchestrator()
        manager = start_manager(context, orchestrator, DateTime.add(DateTime.utc_now(), -7, :second))
        ready = issue(100)
        Tracker.put([ready])

        assert {:ok, assignment} =
                 AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   manager
                 )

        send_codex_token_progress(context, manager, assignment, 5, 7, 12)
        send_codex_token_progress(context, manager, assignment, 9, 11, 20)
        send_codex_token_progress(context, manager, assignment, 9, 11, 20)

        eventually(fn ->
          payload = Presenter.state_payload(orchestrator, 100)

          payload.codex_totals.input_tokens == 9 and
            payload.codex_totals.output_tokens == 11 and
            payload.codex_totals.total_tokens == 20 and
            payload.codex_totals.seconds_running > 0 and
            match?(
              [
                %{
                  tokens: %{input_tokens: 9, output_tokens: 11, total_tokens: 20}
                }
              ],
              payload.running
            )
        end)
      end

      test "revalidation rejects a candidate moved to a terminal state", context do
        ready = issue(1)
        Tracker.put([ready])
        Tracker.replace(%{ready | state: "Done"})

        assert {:ok, {:empty, 5}} = claim(context)
        assert FakePersistence.list_runs_for_issue(ready.identifier) == []
        assert Tracker.updates() == []
      end

      test "claim admission skips active issues with uncleared blocking decisions", context do
        ready = issue(101)
        persist_issue(ready, %{blocking_decision: blocking_decision("failure_retries_exhausted")})
        persist_run(ready.identifier, "run-blocked", context.now)
        Tracker.put([ready])

        log =
          capture_log(fn ->
            assert {:ok, {:empty, 5}, evidence} =
                     AssignmentManager.claim_with_policy_evidence(
                       context.worker.id,
                       context.session.id,
                       %{"available_slots" => 1},
                       :listening_all,
                       1,
                       context.manager
                     )

            assert evidence == %{
                     capacity: 0,
                     reason: :blocking_decision,
                     listening_mode: :listening_all,
                     issue_id: ready.id,
                     issue_identifier: ready.identifier,
                     blocking_decision: %{
                       "decided_at" => "2026-09-12T04:15:33Z",
                       "origin_state" => "Ready",
                       "reason" => "failure_retries_exhausted",
                       "run_id" => "run-blocked"
                     }
                   }
          end)

        assert log =~ "event=worker_claim_skip"
        assert log =~ "skip_reason=blocking_decision"
        assert log =~ "issue_identifier=#{ready.identifier}"
        assert log =~ "origin_state=\"Ready\""
        assert log =~ "run_id=\"run-blocked\""
        assert log =~ "decided_at=\"2026-09-12T04:15:33Z\""
        assert [%{id: "run-blocked"}] = FakePersistence.list_runs_for_issue(ready.identifier)
        assert Tracker.updates() == []
      end

      test "revalidation skips candidates when a blocking decision appears after selection", context do
        ready = issue(102)
        persist_issue(ready)
        Tracker.put([ready])

        Application.put_env(:symphony_elixir, :assignment_test_revalidate_hook, fn ->
          persist_issue(ready, %{blocking_decision: blocking_decision("human_blocked")})
          persist_run(ready.identifier, "run-blocked", context.now)
        end)

        assert {:ok, {:empty, 5}, %{reason: :blocking_decision, issue_identifier: "SYM-102"}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert [%{id: "run-blocked"}] = FakePersistence.list_runs_for_issue(ready.identifier)
        assert Tracker.updates() == []
      end

      test "cleared blocking decisions restore normal claim admission", context do
        ready = issue(103)
        persist_issue(ready, %{blocking_decision: blocking_decision("failure_retries_exhausted")})
        persist_run(ready.identifier, "run-blocked", context.now)
        Tracker.put([ready])

        assert {:ok, {:empty, 5}, %{reason: :blocking_decision}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert :ok = BlockingDecision.clear(ready.identifier)

        assert {:ok, assignment, %{capacity: 1, reason: :assigned}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert assignment.issue_identifier == ready.identifier

        assert [_new_run, %{id: "run-blocked"}] =
                 FakePersistence.list_runs_for_issue(ready.identifier)

        assert Tracker.updates() == [{ready.id, "In Progress"}]
      end

      test "surfaces tracker fetch and state transition failures", context do
        ready = issue(1)
        Tracker.put([ready])
        Tracker.fail_fetch(:tracker_unavailable)
        assert {:error, :tracker_unavailable} = claim(context)

        Tracker.fail_fetch(nil)
        Tracker.fail_update(:transition_rejected)
        assert {:error, :transition_rejected} = claim(context)
        assert [%{status: "failed"}] = FakePersistence.list_runs_for_issue(ready.identifier)
        assert AssignmentManager.current_assignment(context.manager) == nil
      end

      test "claims Todo refinement issues into Refining and returns refinement payload state", context do
        todo = %{issue(2) | state: "Todo"}
        Tracker.put([todo])

        assert {:ok, assignment} = claim(context)

        assert Tracker.updates() == [{todo.id, "Refining"}]
        assert assignment.issue.state == "Refining"
        assert assignment.payload["issue"]["state"] == "Refining"
        assert assignment.payload["workflow_profile"] == "refinement"
        assert assignment.payload["handoff"]["allowed_updates"]["target_states"] == ["Needs Refinement Review"]
        assert assignment.payload["prompt"] =~ "Current status: Refining"
        assert assignment.payload["prompt"] =~ "Needs Refinement Review"
      end

      test "claims Ready implementation issues into In Progress and returns implementation payload state", context do
        ready = issue(3)
        Tracker.put([ready])

        assert {:ok, assignment} = claim(context)

        assert Tracker.updates() == [{ready.id, "In Progress"}]
        assert assignment.issue.state == "In Progress"
        assert assignment.payload["issue"]["state"] == "In Progress"
        assert assignment.payload["workflow_profile"] == "implementation"
        assert assignment.payload["handoff"]["allowed_updates"]["target_states"] == ["In Progress", "Ready to Merge"]
        assert assignment.payload["prompt"] =~ "Current status: In Progress"
        assert assignment.payload["prompt"] =~ "Ready to Merge"
        assert assignment.admission.execution_mode == "worker"
        assert assignment.admission.workspace_authority == {:http_worker, context.worker.id, context.session.id}
        assert assignment.payload["execution_mode"] == assignment.admission.execution_mode
        assert assignment.payload["source"] == stringify_keys(assignment.admission.source)
        assert assignment.payload["limits"] == stringify_keys(assignment.admission.limits)

        assert %{execution_mode: "worker"} = FakePersistence.get_run(assignment.run_id)
      end

      test "fails Todo refinement claim visibly when Linear rejects Refining transition", context do
        todo = %{issue(4) | state: "Todo"}
        Tracker.put([todo])
        Tracker.fail_update(:transition_rejected)

        assert {:error, :transition_rejected} = claim(context)
        assert Tracker.updates() == []
        assert [%{status: "failed"}] = FakePersistence.list_runs_for_issue(todo.identifier)
        assert AssignmentManager.current_assignment(context.manager) == nil
      end

      test "Refining latest running worker run blocks duplicate assignment", context do
        enable_active_state("Refining")
        refining = %{issue(5) | state: "Refining"}
        Tracker.put([refining])
        {:ok, _run} = FakePersistence.create_run(%{issue_identifier: refining.identifier, status: "running", started_at: context.now})

        assert {:ok, {:empty, 5}} = claim(context)
        assert Tracker.updates() == []
      end
    end
  end
end

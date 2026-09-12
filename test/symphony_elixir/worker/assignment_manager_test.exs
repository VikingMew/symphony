defmodule SymphonyElixir.Worker.AssignmentManagerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.EnvironmentFailureCircuit
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore
  alias SymphonyElixirWeb.Presenter

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
      Agent.get_and_update(__MODULE__, fn
        %{fetch_error: nil, candidates: candidates} = state ->
          {{:ok, candidates}, %{state | fetch_count: state.fetch_count + 1}}

        %{fetch_error: reason} = state ->
          {{:error, reason}, %{state | fetch_count: state.fetch_count + 1}}
      end)
    end

    def fetch_issue_states_by_ids(ids) do
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
      Agent.start_link(fn -> %{candidates: %{}, current: %{}, fetches: [], updates: []} end, name: __MODULE__)
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

    def fetch_issues_by_states(states), do: {:ok, Agent.get(__MODULE__, &(&1.current |> Map.values() |> Enum.filter(fn issue -> issue.state in states end)))}

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

  defmodule ZombieReconcilePersistence do
    defdelegate list_runs_for_issue(identifier, opts), to: FakePersistence
    defdelegate finish_run(run_id, status, summary), to: FakePersistence
    defdelegate record_event(attrs), to: FakePersistence
    defdelegate worker_lease_duration_seconds(), to: FakePersistence

    def expire_stale_worker_sessions(_opts \\ []), do: raise("zombie reconciliation must not expire worker sessions")
  end

  defmodule BlockingHeartbeatPersistence do
    defdelegate active_worker_session(worker_id, session_id), to: FakePersistence
    defdelegate expire_stale_worker_sessions(opts \\ []), to: FakePersistence
    defdelegate worker_lease_duration_seconds(), to: FakePersistence

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

  setup do
    FakePersistence.reset!()
    start_supervised!(Tracker)
    circuit = Module.concat(__MODULE__, "Circuit#{System.unique_integer([:positive])}")
    start_supervised!({EnvironmentFailureCircuit, name: circuit})
    {:ok, loaded} = Workflow.load()
    workflow = Map.put(loaded, :project_id, "fake-project-id")
    Application.put_env(:symphony_elixir, :assignment_test_workflow, workflow)
    {:ok, registration} = FakePersistence.register_worker(%{"worker_name" => "test", "total_slots" => 1})
    now = DateTime.utc_now()
    name = Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {AssignmentManager, name: name, tracker: Tracker, persistence: FakePersistence, workflows: Workflows, now: fn -> now end, failure_circuit: circuit, reconcile_interval_ms: :timer.hours(1)}
      )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :assignment_test_workflow)
      Application.delete_env(:symphony_elixir, :assignment_test_workflow_count)
      Application.delete_env(:symphony_elixir, :assignment_test_owner)
      Application.delete_env(:symphony_elixir, :assignment_test_heartbeat_mode)
    end)

    %{manager: pid, worker: registration.worker, session: registration.session, now: now, circuit: circuit}
  end

  test "serializes live claims and creates a fresh assignment after completion", context do
    issues = for number <- 1..12, do: issue(number)
    Tracker.put(issues)

    first_claim = Task.async(fn -> claim(context) end)
    second_claim = Task.async(fn -> claim(context) end)
    results = Enum.map([first_claim, second_claim], &Task.await/1)
    assert Enum.count(results, &match?({:ok, %{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, {:empty, 5}})) == 1

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

  test "accepted worker assignment feeds current state until terminal completion", context do
    orchestrator = start_orchestrator()
    manager = start_manager(context, orchestrator, DateTime.add(DateTime.utc_now(), -5, :second))
    ready = issue(99)
    Tracker.put([ready])

    assert {:ok, assignment} = AssignmentManager.claim(context.worker.id, context.session.id, %{"available_slots" => 1}, manager)

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

    assert {:ok, assignment} = AssignmentManager.claim(context.worker.id, context.session.id, %{"available_slots" => 1}, manager)

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

  test "failure ends the assignment and the next claim rereads Linear", context do
    ready = issue(1)
    Tracker.put([ready])
    assert {:ok, assignment} = claim(context)

    assert {:ok, _event} =
             AssignmentManager.record_event(
               context.worker.id,
               context.session.id,
               assignment.id,
               "task.failed",
               %{"correlation" => assignment.correlation, "summary" => summary("failed")},
               context.manager
             )

    Tracker.put([])
    assert {:ok, {:empty, 5}} = claim(context)
    Tracker.put([ready])
    assert {:ok, next} = claim(context)
    assert next.id == assignment.id == false
    assert next.run_id == assignment.run_id == false
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
    assert FakePersistence.calls() == calls_before

    send(blocked_pid, :release_reconcile)
  end

  test "zombie reconciliation uses run lease without expiring worker sessions", context do
    ready = issue(1)
    Tracker.put([ready])
    assert {:ok, assignment} = claim(context)
    Process.exit(context.manager, :normal)
    Process.sleep(10)

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
    eventually(fn -> List.last(Tracker.updates()) == {ready.id, "Ready"} end)
    assert FakePersistence.get_run(assignment.run_id).status == "failed"
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
    assert {:ok, {:empty, 5}} = AssignmentManager.claim(context.worker.id, context.session.id, %{"available_slots" => 0}, context.manager)

    assert {:ok, {:empty, 5}, %{capacity: 0, reason: :no_available_slots}} =
             AssignmentManager.claim_with_evidence(context.worker.id, context.session.id, %{"available_slots" => 0}, context.manager)

    assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_not_found}} =
             AssignmentManager.claim_with_evidence("wrong", "wrong", %{"available_slots" => 1}, context.manager)

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

    assert :ok = AssignmentManager.cancel_current("operator", context.manager)
    assert AssignmentManager.current_assignment(context.manager) == nil
    assert :ok = AssignmentManager.cancel_current("operator", context.manager)
  end

  test "stale online sessions have zero admission capacity", context do
    Tracker.put([issue(1)])

    Agent.update(FakePersistence, fn state ->
      update_in(state.worker_sessions, fn sessions ->
        Enum.map(sessions, &%{&1 | last_heartbeat_at: DateTime.add(context.now, -31, :second)})
      end)
    end)

    assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_stale}} =
             AssignmentManager.claim_with_evidence(
               context.worker.id,
               context.session.id,
               %{"available_slots" => 4},
               context.manager
             )

    assert Tracker.updates() == []
  end

  test "one assignment consumes capacity across sessions and advertised slot totals", context do
    Tracker.put([issue(1)])
    {:ok, other} = FakePersistence.register_worker(%{"worker_name" => "other", "total_slots" => 8})
    assert {:ok, first} = claim(context)

    assert {:ok, {:empty, 5}, %{capacity: 0, reason: :active_assignment}} =
             AssignmentManager.claim_with_evidence(
               other.worker.id,
               other.session.id,
               %{"available_slots" => 8},
               context.manager
             )

    complete(context, first)
    Tracker.put([issue(2)])

    assert {:ok, second, %{capacity: 1, reason: :assigned}} =
             AssignmentManager.claim_with_evidence(
               other.worker.id,
               other.session.id,
               %{"available_slots" => 8},
               context.manager
             )

    assert second.id != first.id
    assert second.run_id != first.run_id
  end

  test "expires an assignment before accepting a late event", context do
    Tracker.put([issue(1)])
    assert {:ok, assignment} = claim(context)
    run = FakePersistence.get_run(assignment.run_id)
    {:ok, _} = FakePersistence.update_run(run, %{started_at: DateTime.add(context.now, -61, :second)})

    :sys.replace_state(context.manager, fn state ->
      put_in(state.assignment.expires_at, DateTime.add(context.now, -1, :second))
    end)

    assert {:error, :lease_not_active} =
             AssignmentManager.record_event(
               context.worker.id,
               context.session.id,
               assignment.id,
               "task.progress",
               %{},
               context.manager
             )

    assert FakePersistence.get_run(assignment.run_id).status == "failed"
  end

  test "public API is safe while worker dispatch is disabled", context do
    Process.exit(context.manager, :normal)
    Process.sleep(10)

    assert {:ok, {:empty, 5}} = AssignmentManager.claim(context.worker.id, context.session.id, %{}, context.manager)

    assert {:ok, %{lease_renewals: [], commands: []}} =
             AssignmentManager.heartbeat(context.worker.id, context.session.id, %{}, context.manager)

    assert {:error, :lease_not_active} =
             AssignmentManager.record_event(
               context.worker.id,
               context.session.id,
               "gone",
               "task.progress",
               %{},
               context.manager
             )

    assert AssignmentManager.current_assignment(context.manager) == nil
    assert :ok = AssignmentManager.cancel_current("disabled", context.manager)
  end

  test "restart reconciliation preserves a recent run and resets an expired zombie", context do
    ready = issue(1)
    Tracker.put([ready])
    assert {:ok, assignment} = claim(context)
    Process.exit(context.manager, :normal)
    Process.sleep(10)

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
    Process.sleep(10)
    assert Tracker.updates() == [{ready.id, "In Progress"}]

    run = FakePersistence.get_run(assignment.run_id)
    {:ok, _} = FakePersistence.update_run(run, %{started_at: DateTime.add(context.now, -61, :second)})
    AssignmentManager.reconcile(restarted)
    Process.sleep(10)
    assert List.last(Tracker.updates()) == {ready.id, "Ready"}
    assert FakePersistence.get_run(assignment.run_id).status == "failed"

    assert {:error, :lease_not_active} =
             AssignmentManager.record_event(context.worker.id, context.session.id, assignment.id, "task.completed", %{}, restarted)
  end

  test "empty claims follow the fixed schedule and stay below the hourly query quota", context do
    Application.put_env(:symphony_elixir, :assignment_test_workflow_count, 4)
    Tracker.put([])

    assert Enum.map(1..7, fn _ -> claim(context) end) ==
             [
               {:ok, {:empty, 5}},
               {:ok, {:empty, 30}},
               {:ok, {:empty, 30}},
               {:ok, {:empty, 30}},
               {:ok, {:empty, 30}},
               {:ok, {:empty, 60}},
               {:ok, {:empty, 60}}
             ]

    polls_per_hour = 1 + div(3_600 - 5, 30)
    assert polls_per_hour * 4 < 2_500
  end

  test "tracker errors halt workflow traversal, back off, and recover to the first empty poll", context do
    Application.put_env(:symphony_elixir, :assignment_test_workflow_count, 4)
    Tracker.fail_fetch({:linear_api_status, 429, "limited"})

    assert {:error, {:linear_api_status, 429, "limited"}, 30} = claim(context)
    assert Tracker.fetch_count() == 1
    assert {:error, {:linear_api_status, 429, "limited"}, 60} = claim(context)
    assert Tracker.fetch_count() == 2

    Tracker.fail_fetch({:linear_api_status, 503, "down"})
    assert {:error, {:linear_api_status, 503, "down"}, 60} = claim(context)
    assert Tracker.fetch_count() == 3

    Tracker.fail_fetch({:linear_api_request, :timeout})
    assert {:error, {:linear_api_request, :timeout}, 60} = claim(context)
    assert Tracker.fetch_count() == 4

    Tracker.fail_fetch(nil)
    assert {:ok, {:empty, 5}} = claim(context)
    assert Tracker.fetch_count() == 8
  end

  test "assignment halts workflow traversal and resets empty and error streaks", context do
    Application.put_env(:symphony_elixir, :assignment_test_workflow_count, 4)
    Tracker.put([])
    assert {:ok, {:empty, 5}} = claim(context)
    assert {:ok, {:empty, 30}} = claim(context)

    Tracker.put([issue(1)])
    assert {:ok, assignment} = claim(context)
    assert Tracker.fetch_count() == 9
    complete(context, assignment)

    Tracker.put([])
    assert {:ok, {:empty, 5}} = claim(context)
  end

  test "claim uses persisted project workflow context for prompt and correlation", context do
    start_supervised!(ProjectTracker)
    {:ok, base} = Workflow.load()
    {:ok, default_project} = FakePersistence.default_project()

    {:ok, project_b} =
      FakePersistence.update_project(default_project.id, %{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@example.test:b.git",
        default_branch: "main",
        checkout_depth: 1,
        source_strategy: "clone",
        worktree_fetch: true,
        worktree_cleanup: true,
        enabled: true
      })

    {:ok, _project_b_workflow} =
      FakePersistence.import_workflow(
        project_b,
        workflow_markdown(base, "Prompt B {{ issue.identifier }}"),
        "test"
      )

    {:ok, project_a} =
      FakePersistence.create_project(%{
        name: "Project A",
        slug: "project-a",
        linear_project_slug: "linear-a",
        repository_url: "git@example.test:a.git",
        enabled: true
      })

    {:ok, _project_a_workflow} =
      FakePersistence.import_workflow(
        project_a,
        workflow_markdown(base, "Prompt A {{ issue.identifier }}"),
        "test"
      )

    assert :ok = WorkflowStore.force_reload()
    assert Enum.map(WorkflowStore.list_enabled(), & &1.project_id) == [project_a.id, project_b.id]
    assert {:error, :missing_project_context} = WorkflowStore.current()

    issue_b = issue(78)
    ProjectTracker.put(%{"linear-a" => [], "linear-b" => [issue_b]})

    manager_name = Module.concat(__MODULE__, "PersistedManager#{System.unique_integer([:positive])}")

    manager =
      start_supervised!(
        Supervisor.child_spec(
          {AssignmentManager,
           name: manager_name,
           tracker: ProjectTracker,
           persistence: FakePersistence,
           workflows: WorkflowStore,
           now: fn -> context.now end,
           failure_circuit: context.circuit,
           reconcile_interval_ms: :timer.hours(1)},
          id: manager_name
        )
      )

    assert {:ok, assignment} =
             AssignmentManager.claim(
               context.worker.id,
               context.session.id,
               %{"available_slots" => 1},
               manager
             )

    assert ProjectTracker.fetches() == ["linear-a", "linear-b"]
    assert assignment.project_id == project_b.id
    assert assignment.correlation["project_id"] == project_b.id
    assert assignment.payload["repository"]["project_id"] == project_b.id
    assert assignment.payload["prompt"] =~ "Prompt B SYM-78"
    refute assignment.payload["prompt"] =~ "Prompt A"
    refute assignment.payload["prompt"] =~ "You are an agent for this repository."

    run = FakePersistence.get_run(assignment.run_id)
    assert run.project_id == project_b.id

    persisted_issue = FakePersistence.get_issue_by_identifier(issue_b.identifier)
    assert persisted_issue.project_id == project_b.id
  end

  test "docs/spec-reliability-security.md §14.5 and docs/spec-observability.md §13.8: stub worker failures open the circuit once",
       context do
    for number <- 1..EnvironmentFailureCircuit.threshold() do
      Tracker.put([issue(number)])
      assert {:ok, assignment} = claim(context)

      assert {:ok, _event} =
               AssignmentManager.record_event(
                 context.worker.id,
                 context.session.id,
                 assignment.id,
                 "task.failed",
                 %{
                   "correlation" => assignment.correlation,
                   "summary" => failure_summary("bwrap: No permissions to create a new namespace")
                 },
                 context.manager
               )
    end

    [alert] = FakePersistence.list_events(event_type: EnvironmentFailureCircuit.event_type())
    assert alert.payload.triggering_fingerprint == EnvironmentFailureCircuit.fingerprint("bwrap: No permissions to create a new namespace")
    assert alert.payload.issue_identifiers == ["SYM-1", "SYM-2", "SYM-3"]
    assert alert.payload.distinct_issue_count == EnvironmentFailureCircuit.threshold()

    assert %{active: true, triggering_fingerprint: fingerprint} = EnvironmentFailureCircuit.snapshot(context.circuit)

    Tracker.put([issue(4)])
    fetch_count = Tracker.fetch_count()

    assert {:ok, {:empty, 60}, %{reason: :environment_failure_circuit_open, failure_fingerprint: ^fingerprint}} =
             AssignmentManager.claim_with_evidence(
               context.worker.id,
               context.session.id,
               %{"available_slots" => 1},
               context.manager
             )

    assert Tracker.fetch_count() == fetch_count

    assert {:ok, assignment} = claim_after_circuit_reset(context, issue(4))

    assert {:ok, _event} =
             AssignmentManager.record_event(
               context.worker.id,
               context.session.id,
               assignment.id,
               "task.failed",
               %{
                 "correlation" => assignment.correlation,
                 "summary" => failure_summary("bwrap: No permissions to create a new namespace")
               },
               context.manager
             )

    assert [_alert] = FakePersistence.list_events(event_type: EnvironmentFailureCircuit.event_type())
  end

  defp claim(context) do
    AssignmentManager.claim(context.worker.id, context.session.id, %{"available_slots" => 1}, context.manager)
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!({Orchestrator, name: name})
    name
  end

  defp start_manager(context, orchestrator, now) do
    name = Module.concat(__MODULE__, "ObservedManager#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec(
        {AssignmentManager,
         name: name,
         tracker: Tracker,
         persistence: FakePersistence,
         workflows: Workflows,
         orchestrator: orchestrator,
         now: fn -> now end,
         failure_circuit: context.circuit,
         reconcile_interval_ms: :timer.hours(1)},
        id: name
      )
    )
  end

  defp send_codex_token_progress(context, manager, assignment, input_tokens, output_tokens, total_tokens) do
    assert {:ok, _event} =
             AssignmentManager.record_event(
               context.worker.id,
               context.session.id,
               assignment.id,
               "task.progress",
               %{
                 "correlation" => assignment.correlation,
                 "phase" => "codex_update",
                 "codex" => %{
                   "event" => "notification",
                   "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
                   "payload" => %{
                     "method" => "thread/tokenUsage/updated",
                     "params" => %{
                       "tokenUsage" => %{
                         "total" => %{
                           "input_tokens" => input_tokens,
                           "output_tokens" => output_tokens,
                           "total_tokens" => total_tokens
                         }
                       }
                     }
                   },
                   "session_id" => "codex-token-session"
                 }
               },
               manager
             )
  end

  defp claim_after_circuit_reset(context, issue) do
    EnvironmentFailureCircuit.reset(context.circuit)
    Tracker.put([issue])
    claim(context)
  end

  defp complete(context, assignment) do
    assert {:ok, _event} =
             AssignmentManager.record_event(
               context.worker.id,
               context.session.id,
               assignment.id,
               "task.completed",
               %{"correlation" => assignment.correlation, "summary" => summary("succeeded")},
               context.manager
             )
  end

  defp issue(number) do
    %Issue{
      id: "issue-#{number}",
      identifier: "SYM-#{number}",
      title: "Issue #{number}",
      description: "Work",
      priority: number,
      state: "Ready",
      branch_name: "sym-#{number}",
      blocked_by: [],
      labels: [],
      assigned_to_worker: true,
      created_at: DateTime.add(~U[2026-09-01 00:00:00Z], number, :second)
    }
  end

  defp summary(outcome) do
    %{
      "phase" => "complete",
      "outcome" => outcome,
      "reason" => if(outcome == "succeeded", do: "completed", else: "worker_error"),
      "occurred_at" => "2026-09-06T10:00:00Z",
      "source_revision" => "abc123",
      "runtime" => %{"image_tag" => "worker:test", "worker_source_revision" => "abc123"},
      "validation_status" => if(outcome == "succeeded", do: "passed", else: "failed"),
      "gates" => []
    }
  end

  defp failure_summary(detail) do
    "failed"
    |> summary()
    |> Map.put("detail", detail)
  end

  defp workflow_markdown(base, prompt), do: Workflow.to_markdown(base.config, prompt)

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end

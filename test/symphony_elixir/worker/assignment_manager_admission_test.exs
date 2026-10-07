defmodule SymphonyElixir.Worker.AssignmentManagerAdmissionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.EnvironmentFailureCircuit
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.Events
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixir.Workflow

  defmodule Tracker do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{issues: [], reconcile_error: nil, reconcile_fetches: 0} end, name: __MODULE__)
    end

    def put(issues), do: Agent.update(__MODULE__, &%{&1 | issues: issues})
    def fail_reconcile(reason), do: Agent.update(__MODULE__, &%{&1 | reconcile_error: reason})
    def reconcile_fetches, do: Agent.get(__MODULE__, & &1.reconcile_fetches)

    def fetch_candidate_issues, do: {:ok, Agent.get(__MODULE__, & &1.issues)}

    def fetch_issue_states_by_ids(ids) do
      {:ok, Agent.get(__MODULE__, fn state -> Enum.filter(state.issues, &(&1.id in ids)) end)}
    end

    def fetch_issues_by_states(states) do
      Agent.get_and_update(__MODULE__, fn state ->
        issues = Enum.filter(state.issues, &(&1.state in states))
        result = if state.reconcile_error, do: {:error, state.reconcile_error}, else: {:ok, issues}
        {result, %{state | reconcile_fetches: state.reconcile_fetches + 1}}
      end)
    end

    def update_issue_state(id, next_state) do
      Agent.update(__MODULE__, fn state ->
        issues = Enum.map(state.issues, &if(&1.id == id, do: %{&1 | state: next_state}, else: &1))
        %{state | issues: issues}
      end)

      :ok
    end
  end

  defmodule Workflows do
    def list_enabled, do: [Application.fetch_env!(:symphony_elixir, :assignment_admission_workflow)]
  end

  setup do
    previous_execution_mode = Application.get_env(:symphony_elixir, :execution_mode)
    Application.put_env(:symphony_elixir, :execution_mode, :worker)
    FakePersistence.reset!()
    start_supervised!(Tracker)

    circuit = Module.concat(__MODULE__, "Circuit#{System.unique_integer([:positive])}")
    start_supervised!({EnvironmentFailureCircuit, name: circuit})
    {:ok, loaded} = Workflow.load()
    Application.put_env(:symphony_elixir, :assignment_admission_workflow, Map.put(loaded, :project_id, "fake-project-id"))
    {:ok, registration} = FakePersistence.register_worker(%{"worker_name" => "test", "total_slots" => 1})
    now = DateTime.utc_now()
    manager = start_manager(now, circuit)
    :ok = AssignmentManager.observe_session(registration.worker, registration.session, manager)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :assignment_admission_workflow)
      Application.delete_env(:symphony_elixir, :fake_admit_run_hook)

      if is_nil(previous_execution_mode),
        do: Application.delete_env(:symphony_elixir, :execution_mode),
        else: Application.put_env(:symphony_elixir, :execution_mode, previous_execution_mode)
    end)

    %{manager: manager, worker: registration.worker, session: registration.session, now: now, circuit: circuit}
  end

  test "independent managers atomically admit one run for the same issue", context do
    owner = self()
    Tracker.put([issue()])
    second = start_manager(context.now, context.circuit)
    :ok = AssignmentManager.observe_session(context.worker, context.session, second)

    Application.put_env(:symphony_elixir, :fake_admit_run_hook, fn ->
      send(owner, {:admission_barrier, self()})
      receive do: (:release_admission -> :ok)
    end)

    claims = Enum.map([context.manager, second], &Task.async(fn -> claim_with_evidence(context, &1) end))
    barrier_pids = for _ <- 1..2, do: receive(do: ({:admission_barrier, pid} -> pid))
    Enum.each(barrier_pids, &send(&1, :release_admission))
    results = Enum.map(claims, &Task.await(&1, 2_000))

    assert Enum.count(results, &match?({:ok, %{}, %{reason: :assigned}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:empty, 5}, %{reason: :active_run}}, &1)) == 1
    assert [%{status: "running"}] = FakePersistence.list_runs(status: "running")
    assert Enum.count([context.manager, second], &(AssignmentManager.current_assignment(&1) != nil)) == 1
  end

  test "explicit Todo admission terminates an expired orphan before creating one run", context do
    todo = %{issue() | state: "Todo"}
    Tracker.put([todo])
    {:ok, issue_record} = persist_issue(todo)

    {:ok, orphan} =
      FakePersistence.create_run(%{
        id: "orphan-run",
        project_id: "fake-project-id",
        issue_id: issue_record.id,
        issue_identifier: todo.identifier,
        status: "running",
        started_at: DateTime.add(context.now, -61, :second)
      })

    assert {:ok, assignment} = claim(context, context.manager)
    assert assignment.run_id != orphan.id
    assert %{status: "failed", failure_reason: "assignment_expired", finished_at: %DateTime{}} = FakePersistence.get_run(orphan.id)
    assert [%{id: run_id, status: "running"}] = FakePersistence.list_runs(status: "running")
    assert run_id == assignment.run_id
  end

  test "an expired running row is not replaced while the issue remains Ready", context do
    ready = issue()
    Tracker.put([ready])
    {:ok, issue_record} = persist_issue(ready)

    {:ok, orphan} =
      FakePersistence.create_run(%{
        id: "ready-orphan-run",
        project_id: "fake-project-id",
        issue_id: issue_record.id,
        issue_identifier: ready.identifier,
        status: "running",
        started_at: DateTime.add(context.now, -61, :second)
      })

    assert {:ok, {:empty, 5}, %{reason: :active_run, run_id: "ready-orphan-run"}} =
             claim_with_evidence(context, context.manager)

    assert %{status: "running"} = persisted_orphan = FakePersistence.get_run(orphan.id)
    assert Map.get(persisted_orphan, :finished_at) == nil
    assert [^orphan] = FakePersistence.list_runs(status: "running")
    assert AssignmentManager.current_assignment(context.manager) == nil
  end

  test "reconciliation persists each Linear failure and resumes on the next round", context do
    Enum.with_index([400, 429, 503], 1)
    |> Enum.each(fn {status, expected_count} ->
      Tracker.fail_reconcile({:linear_api_status, status, "failed"})
      AssignmentManager.reconcile(context.manager)
      eventually(fn -> Tracker.reconcile_fetches() == expected_count end)
      eventually(fn -> length(FakePersistence.list_events(event_type: "linear.request_failed")) == expected_count end)
      Process.sleep(20)
      assert Tracker.reconcile_fetches() == expected_count
    end)

    statuses = FakePersistence.list_events(event_type: "linear.request_failed") |> Enum.map(& &1.payload["status"]) |> Enum.sort()
    assert statuses == [400, 429, 503]

    Tracker.fail_reconcile(nil)
    AssignmentManager.reconcile(context.manager)
    eventually(fn -> Tracker.reconcile_fetches() == 4 end)
    assert length(FakePersistence.list_events(event_type: "linear.request_failed")) == 3
  end

  defp start_manager(now, circuit) do
    name = Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: name,
      start:
        {AssignmentManager, :start_link,
         [[name: name, tracker: Tracker, persistence: FakePersistence, workflows: Workflows, now: fn -> now end, failure_circuit: circuit, reconcile_interval_ms: :timer.hours(1)]]}
    })
  end

  defp claim(context, manager) do
    AssignmentManager.claim_with_policy(
      context.worker.id,
      context.session.id,
      %{"available_slots" => 1},
      :listening_all,
      1,
      manager
    )
  end

  defp claim_with_evidence(context, manager) do
    AssignmentManager.claim_with_policy_evidence(
      context.worker.id,
      context.session.id,
      %{"available_slots" => 1},
      :listening_all,
      1,
      manager
    )
  end

  defp issue do
    %Issue{
      id: "issue-atomic",
      identifier: "SYM-ATOMIC",
      title: "Atomic admission",
      description: "Work",
      priority: 1,
      state: "Ready",
      branch_name: "sym-atomic",
      blocked_by: [],
      labels: [],
      assigned_to_worker: true,
      created_at: ~U[2026-09-01 00:00:00Z]
    }
  end

  defp persist_issue(issue) do
    issue
    |> Events.issue_attrs()
    |> Map.put(:project_id, "fake-project-id")
    |> FakePersistence.upsert_issue()
  end

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

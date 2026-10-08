defmodule SymphonyElixir.Worker.AssignmentManagerBlockingDecisionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.EnvironmentFailureCircuit
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.Events
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixir.Workflow

  defmodule Tracker do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{candidates: [], current: %{}, updates: []} end, name: __MODULE__)

    def put(issues) do
      Agent.update(__MODULE__, fn state ->
        %{state | candidates: issues, current: Map.new(issues, &{&1.id, &1})}
      end)
    end

    def updates, do: Agent.get(__MODULE__, &Enum.reverse(&1.updates))
    def fetch_candidate_issues, do: {:ok, Agent.get(__MODULE__, & &1.candidates)}

    def fetch_issue_states_by_ids(ids) do
      {:ok, Agent.get(__MODULE__, &Enum.map(ids, fn id -> &1.current[id] end))}
    end

    def fetch_issues_by_states(states) do
      {:ok, Agent.get(__MODULE__, &Enum.filter(Map.values(&1.current), fn issue -> issue.state in states end))}
    end

    def update_issue_state(id, state) do
      Agent.update(__MODULE__, fn data ->
        %{data | current: Map.update!(data.current, id, &%{&1 | state: state}), updates: [{id, state} | data.updates]}
      end)

      :ok
    end
  end

  defmodule Workflows do
    def list_enabled, do: [Application.fetch_env!(:symphony_elixir, :blocking_decision_test_workflow)]
  end

  setup do
    previous_execution_mode = Application.get_env(:symphony_elixir, :execution_mode)
    Application.put_env(:symphony_elixir, :execution_mode, :worker)
    FakePersistence.reset!()
    start_supervised!(Tracker)
    circuit = Module.concat(__MODULE__, "Circuit#{System.unique_integer([:positive])}")
    start_supervised!({EnvironmentFailureCircuit, name: circuit})
    {:ok, loaded} = Workflow.load_example_package()
    Application.put_env(:symphony_elixir, :blocking_decision_test_workflow, Map.put(loaded, :project_id, "fake-project-id"))
    {:ok, registration} = FakePersistence.register_worker(%{"worker_name" => "test", "total_slots" => 1})
    now = DateTime.utc_now()
    orchestrator = start_orchestrator()
    manager = start_manager(registration, circuit, orchestrator, now)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :blocking_decision_test_workflow)
      Application.delete_env(:symphony_elixir, :blocking_decision_cas_hook)

      if is_nil(previous_execution_mode),
        do: Application.delete_env(:symphony_elixir, :execution_mode),
        else: Application.put_env(:symphony_elixir, :execution_mode, previous_execution_mode)
    end)

    %{
      manager: manager,
      worker: registration.worker,
      session: registration.session,
      orchestrator: orchestrator,
      now: now
    }
  end

  test "state mismatch clears the old decision and projections before claiming the new run", context do
    todo = %{issue(104) | state: "Todo"}

    persist_issue(%{todo | state: "In Progress"}, %{
      blocking_decision: blocking_decision("failure_retries_exhausted", origin_state: "In Progress", run_id: "run-old"),
      no_progress_streak: 2
    })

    persist_run(todo.identifier, "run-old", DateTime.add(context.now, -60, :second))
    Tracker.put([todo])

    :sys.replace_state(context.orchestrator, fn state ->
      %{
        state
        | blocked: %{todo.id => %{run_id: "run-old"}},
          retry_attempts: %{todo.id => %{timer_ref: nil}},
          failure_counts: %{todo.id => 3},
          claimed: MapSet.put(state.claimed, todo.id)
      }
    end)

    assert {:ok, assignment, %{reason: :assigned}} = claim(context)
    assert assignment.issue.state == "Refining"
    assert assignment.run_id != "run-old"

    persisted = FakePersistence.get_issue_by_identifier(todo.identifier)
    assert Map.get(persisted, :blocking_decision) == nil
    assert Map.get(persisted, :no_progress_streak, 0) == 0

    assert [event] = cleared_events(todo.identifier)
    assert event.run_id == "run-old"
    assert event.payload["source"] == "candidate_selection"
    assert event.payload["cause"] == "state_mismatch"
    assert event.payload["origin_state"] == "In Progress"

    state = :sys.get_state(context.orchestrator)
    assert state.blocked == %{}
    assert state.retry_attempts == %{}
    assert state.failure_counts == %{}
    assert state.running[todo.id].run_id == assignment.run_id
    assert MapSet.member?(state.claimed, todo.id)
  end

  test "a newer manual run invalidates the old decision without a state change", context do
    ready = issue(105)

    persist_issue(ready, %{
      blocking_decision: blocking_decision("failure_retries_exhausted", origin_state: "Ready", run_id: "run-old"),
      no_progress_streak: 2
    })

    persist_run(ready.identifier, "run-old", DateTime.add(context.now, -60, :second))
    persist_run(ready.identifier, "run-manual", DateTime.add(context.now, -30, :second))
    Tracker.put([ready])

    assert {:ok, assignment, %{reason: :assigned}} = claim(context)
    assert assignment.issue_identifier == ready.identifier
    assert assignment.run_id not in ["run-old", "run-manual"]

    persisted = FakePersistence.get_issue_by_identifier(ready.identifier)
    assert Map.get(persisted, :blocking_decision) == nil
    assert Map.get(persisted, :no_progress_streak, 0) == 0

    assert [event] = cleared_events(ready.identifier)
    assert event.payload["cause"] == "run_superseded"
    assert event.payload["run_id"] == "run-old"
  end

  test "missing decision scope is cleared with an explicit cause before the same claim continues", context do
    ready = issue(106)
    legacy = blocking_decision("failure_retries_exhausted") |> Map.delete("origin_state")
    persist_issue(ready, %{blocking_decision: legacy, no_progress_streak: 2})
    persist_run(ready.identifier, "run-blocked", context.now)
    Tracker.put([ready])

    assert {:ok, assignment, %{reason: :assigned}} = claim(context)
    assert assignment.issue_identifier == ready.identifier
    assert [event] = cleared_events(ready.identifier)
    assert event.payload["cause"] == "missing_scope"
    assert Map.get(FakePersistence.get_issue_by_identifier(ready.identifier), :blocking_decision) == nil
  end

  test "CAS replacement is re-read and a new valid decision remains blocking", context do
    ready = issue(107)
    old = blocking_decision("failure_retries_exhausted", origin_state: "In Progress", run_id: "run-old")
    replacement = blocking_decision("reported_blocker", origin_state: "Ready", run_id: "run-new")

    persist_issue(ready, %{blocking_decision: old, no_progress_streak: 2})
    persist_run(ready.identifier, "run-old", DateTime.add(context.now, -60, :second))
    Tracker.put([ready])

    :sys.replace_state(context.orchestrator, fn state ->
      %{
        state
        | blocked: %{ready.id => %{run_id: "run-new"}},
          retry_attempts: %{ready.id => %{timer_ref: nil, run_id: "run-new"}},
          failure_counts: %{ready.id => 1},
          claimed: MapSet.put(state.claimed, ready.id)
      }
    end)

    Application.put_env(:symphony_elixir, :blocking_decision_cas_hook, fn ->
      persist_run(ready.identifier, "run-new", context.now)
      current = FakePersistence.get_issue_by_identifier(ready.identifier)
      {:ok, _issue} = FakePersistence.update_issue(current, %{blocking_decision: replacement, no_progress_streak: 7})
      Application.delete_env(:symphony_elixir, :blocking_decision_cas_hook)
    end)

    assert {:ok, {:empty, 5}, %{reason: :blocking_decision}} = claim(context)
    persisted = FakePersistence.get_issue_by_identifier(ready.identifier)
    assert persisted.blocking_decision == replacement
    assert persisted.no_progress_streak == 7
    assert cleared_events(ready.identifier) == []
    assert Tracker.updates() == []

    state = :sys.get_state(context.orchestrator)
    assert state.blocked[ready.id].run_id == "run-new"
    assert state.retry_attempts[ready.id].run_id == "run-new"
    assert state.failure_counts[ready.id] == 1
    assert MapSet.member?(state.claimed, ready.id)
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!({Orchestrator, name: name})
    name
  end

  defp start_manager(registration, circuit, orchestrator, now) do
    name = Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")

    manager =
      start_supervised!(
        {AssignmentManager,
         name: name,
         tracker: Tracker,
         persistence: FakePersistence,
         workflows: Workflows,
         orchestrator: orchestrator,
         now: fn -> now end,
         failure_circuit: circuit,
         reconcile_interval_ms: :timer.hours(1)}
      )

    :ok = AssignmentManager.observe_session(registration.worker, registration.session, manager)
    manager
  end

  defp claim(context) do
    AssignmentManager.claim_with_policy_evidence(
      context.worker.id,
      context.session.id,
      %{"available_slots" => 1},
      :listening_all,
      1,
      context.manager
    )
  end

  defp cleared_events(identifier) do
    FakePersistence.list_events(issue_identifier: identifier, event_type: "issue.blocking_decision_cleared")
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

  defp persist_issue(issue, attrs) do
    issue
    |> Events.issue_attrs()
    |> Map.put(:project_id, "fake-project-id")
    |> Map.merge(attrs)
    |> FakePersistence.upsert_issue()
  end

  defp persist_run(identifier, id, started_at) do
    FakePersistence.create_run(%{id: id, issue_identifier: identifier, status: "failed", started_at: started_at})
  end

  defp blocking_decision(reason, opts \\ []) do
    %{
      "decided_at" => "2026-09-12T04:15:33Z",
      "evidence" => "test",
      "reason" => reason,
      "run_id" => Keyword.get(opts, :run_id, "run-blocked"),
      "origin_state" => Keyword.get(opts, :origin_state, "Ready"),
      "comment_status" => "pending",
      "transition_status" => Keyword.get(opts, :transition_status, "pending")
    }
  end
end

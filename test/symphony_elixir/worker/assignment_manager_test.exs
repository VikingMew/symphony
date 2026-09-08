defmodule SymphonyElixir.Worker.AssignmentManagerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixir.Workflow

  defmodule Tracker do
    use Agent

    def start_link(_opts) do
      initial = %{candidates: [], current: %{}, updates: [], fetch_error: nil, update_error: nil}
      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def put(issues), do: Agent.update(__MODULE__, &%{&1 | candidates: issues, current: Map.new(issues, fn issue -> {issue.id, issue} end)})
    def replace(issue), do: Agent.update(__MODULE__, &put_in(&1.current[issue.id], issue))
    def fail_fetch(reason), do: Agent.update(__MODULE__, &%{&1 | fetch_error: reason})
    def fail_update(reason), do: Agent.update(__MODULE__, &%{&1 | update_error: reason})
    def updates, do: Agent.get(__MODULE__, &Enum.reverse(&1.updates))

    def fetch_candidate_issues do
      Agent.get(__MODULE__, fn
        %{fetch_error: nil, candidates: candidates} -> {:ok, candidates}
        %{fetch_error: reason} -> {:error, reason}
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
    def list_enabled, do: [Application.fetch_env!(:symphony_elixir, :assignment_test_workflow)]
  end

  setup do
    FakePersistence.reset!()
    start_supervised!(Tracker)
    {:ok, loaded} = Workflow.load()
    workflow = Map.put(loaded, :project_id, "fake-project-id")
    Application.put_env(:symphony_elixir, :assignment_test_workflow, workflow)
    {:ok, registration} = FakePersistence.register_worker(%{"worker_name" => "test", "total_slots" => 1})
    now = DateTime.utc_now()
    name = Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")

    pid =
      start_supervised!({AssignmentManager, name: name, tracker: Tracker, persistence: FakePersistence, workflows: Workflows, now: fn -> now end, reconcile_interval_ms: :timer.hours(1)})

    on_exit(fn -> Application.delete_env(:symphony_elixir, :assignment_test_workflow) end)

    %{manager: pid, worker: registration.worker, session: registration.session, now: now}
  end

  test "serializes live claims and creates a fresh assignment after completion", context do
    issues = for number <- 1..12, do: issue(number)
    Tracker.put(issues)

    first_claim = Task.async(fn -> claim(context) end)
    second_claim = Task.async(fn -> claim(context) end)
    results = Enum.map([first_claim, second_claim], &Task.await/1)
    assert Enum.count(results, &match?({:ok, %{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, nil})) == 1

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

  test "revalidation rejects a candidate moved to a terminal state", context do
    ready = issue(1)
    Tracker.put([ready])
    Tracker.replace(%{ready | state: "Done"})

    assert {:ok, nil} = claim(context)
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
    assert {:ok, nil} = claim(context)
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
    assert {:ok, nil} = AssignmentManager.claim(context.worker.id, context.session.id, %{"available_slots" => 0}, context.manager)
    assert {:error, :worker_session_not_found} = AssignmentManager.claim("wrong", "wrong", %{}, context.manager)
    assert {:error, :worker_session_not_found} = AssignmentManager.heartbeat("wrong", "wrong", %{}, context.manager)
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

    assert {:ok, nil} = AssignmentManager.claim(context.worker.id, context.session.id, %{}, context.manager)

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
      AssignmentManager.start_link(name: name, tracker: Tracker, persistence: FakePersistence, workflows: Workflows, now: fn -> context.now end, reconcile_interval_ms: :timer.hours(1))

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

  defp claim(context) do
    AssignmentManager.claim(context.worker.id, context.session.id, %{"available_slots" => 1}, context.manager)
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
end

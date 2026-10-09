defmodule SymphonyElixir.Worker.AssignmentManagerClaimTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SymphonyElixir.{EnvironmentFailureCircuit, Workflow}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager

  defmodule Tracker do
    use Agent

    def start_link(_opts),
      do:
        (
          {:ok, workflow} = Workflow.load_example_package()

          Agent.start_link(
            fn ->
              %{
                issue: %Issue{
                  id: "claim-issue",
                  identifier: "SYM-CLAIM",
                  title: "Claim",
                  description: "Work",
                  priority: 1,
                  state: "Ready",
                  project_slug: get_in(workflow.config, ["tracker", "project_slug"]),
                  blocked_by: [],
                  labels: [],
                  assigned_to_worker: true
                },
                updates: 0,
                mode: :normal
              }
            end,
            name: __MODULE__
          )
        )

    def set_mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})
    def put_issue(issue), do: Agent.update(__MODULE__, &%{&1 | issue: issue})
    def updates, do: Agent.get(__MODULE__, & &1.updates)
    def fetch_candidate_issues, do: {:ok, [Agent.get(__MODULE__, & &1.issue)]}
    def fetch_issue_states_by_ids(_ids), do: fetch_candidate_issues()
    def fetch_issues_by_states(_states), do: {:ok, []}

    def update_issue_state(_id, target) do
      mode = Agent.get_and_update(__MODULE__, fn data -> {data.mode, %{data | issue: %{data.issue | state: target}, updates: data.updates + 1, mode: :normal}} end)

      case mode do
        :normal -> :ok
        :lost_reply -> exit(:lost_linear_reply)
      end
    end
  end

  defmodule Workflows do
    def list_enabled do
      case Application.get_env(:symphony_elixir, :claim_test_workflows) do
        workflows when is_list(workflows) -> workflows
        nil -> default_workflow()
      end
    end

    defp default_workflow do
      {:ok, loaded} = Workflow.load_example_package()

      config =
        case Application.get_env(:symphony_elixir, :claim_test_fallback_project_slug) do
          nil -> loaded.config
          slug -> Map.put(loaded.config, "dispatch_scope", %{"fallback_project_slug" => slug})
        end

      [%{loaded | config: config} |> Map.put(:project_id, "fake-project-id") |> Map.put(:project_slug, "fallback-project")]
    end
  end

  defmodule Persistence do
    defdelegate worker_heartbeat_interval_seconds(), to: FakePersistence
    defdelegate worker_lease_duration_seconds(), to: FakePersistence
    defdelegate worker_session_identity(worker, session), to: FakePersistence

    def get_issue_by_identifier(identifier) do
      if hook = Application.get_env(:symphony_elixir, :claim_test_history_hook), do: hook.()
      FakePersistence.get_issue_by_identifier(identifier)
    end

    defdelegate list_runs_for_issue(identifier, opts), to: FakePersistence
    defdelegate get_run(id), to: FakePersistence
    defdelegate get_event(id), to: FakePersistence
    defdelegate finish_run(id, status, attrs), to: FakePersistence

    def record_event(attrs) do
      result = FakePersistence.record_event(attrs)
      if Application.get_env(:symphony_elixir, :claim_test_lost_event_reply), do: exit(:lost_event_reply)
      result
    end

    def admit_issue_run(issue, run, opts) do
      result = FakePersistence.admit_issue_run(issue, run, opts)
      if Application.get_env(:symphony_elixir, :claim_test_lost_run_reply), do: exit(:lost_run_reply)
      result
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :execution_mode)
    Application.put_env(:symphony_elixir, :execution_mode, :worker)
    FakePersistence.reset!()
    start_supervised!(Tracker)
    circuit = start_supervised!({EnvironmentFailureCircuit, name: nil})
    {:ok, registration} = FakePersistence.register_worker(%{"worker_name" => "claim-test", "total_slots" => 1})

    now = DateTime.utc_now()

    manager =
      start_supervised!(
        {AssignmentManager,
         now: fn -> now end, name: nil, tracker: Tracker, persistence: Persistence, workflows: Workflows, failure_circuit: circuit, orchestrator: self(), reconcile_interval_ms: :timer.hours(1)}
      )

    :ok = AssignmentManager.observe_session(registration.worker, registration.session, manager)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :fake_admit_run_hook)
      Application.delete_env(:symphony_elixir, :claim_test_lost_run_reply)
      Application.delete_env(:symphony_elixir, :claim_test_lost_event_reply)
      Application.delete_env(:symphony_elixir, :claim_test_history_hook)
      Application.delete_env(:symphony_elixir, :claim_test_fallback_project_slug)
      Application.delete_env(:symphony_elixir, :claim_test_workflows)

      if previous do
        Application.put_env(:symphony_elixir, :execution_mode, previous)
      else
        Application.delete_env(:symphony_elixir, :execution_mode)
      end
    end)

    %{manager: manager, worker: registration.worker, session: registration.session, now: now}
  end

  test "preparation deadline cannot kill a commit or consume its lease", context do
    owner = self()

    Application.put_env(:symphony_elixir, :fake_admit_run_hook, fn ->
      send(owner, {:commit_waiting, self()})
      receive do: (:release -> :ok)
    end)

    task = Task.async(fn -> claim(context) end)
    assert_receive {:commit_waiting, commit}, 2_000
    %{claim_task: job} = :sys.get_state(context.manager)
    assert job.phase == :commit
    send(context.manager, {:claim_timeout, job.claim_id})
    assert AssignmentManager.current_assignment(context.manager) == nil
    assert Process.alive?(commit)
    assert {:ok, %{commands: [], lease_renewals: []}} = AssignmentManager.heartbeat(context.worker.id, context.session.id, %{"active_leases" => []}, context.manager)
    send(commit, :release)
    assert {:ok, assignment} = Task.await(task)
    assert assignment.expires_at == DateTime.add(context.now, FakePersistence.worker_lease_duration_seconds(), :second)
    assert_single_assignment(context, assignment)
  end

  @tag timeout: 15_000
  test "HTTP caller timeout retains the commit and retry recovers the published assignment", context do
    owner = self()

    Application.put_env(:symphony_elixir, :fake_admit_run_hook, fn ->
      send(owner, {:commit_waiting, self()})
      receive do: (:release -> :ok)
    end)

    task = Task.async(fn -> claim(context) end)
    assert_receive {:commit_waiting, commit}, 2_000
    assert {:error, :claim_pending, 5} = Task.await(task, 7_000)
    assert Process.alive?(commit)
    assert {:ok, {:empty, 5}} = claim(context)
    send(commit, :release)
    assignment = await_assignment(context.manager)
    assert_single_assignment(context, assignment)
  end

  test "lost Linear update response recovers the same run without repeating the transition", context do
    Tracker.set_mode(:lost_reply)

    capture_log(fn ->
      assert {:error, :claim_pending, 30} = claim(context)
      [run] = FakePersistence.list_runs_for_issue("SYM-CLAIM")
      retry_commit(context.manager)
      assignment = await_assignment(context.manager)
      assert assignment.run_id == run.id
      assert Tracker.updates() == 1
      assert_single_assignment(context, assignment)
    end)
  end

  test "lost database commit response recovers the preallocated run identity", context do
    Application.put_env(:symphony_elixir, :claim_test_lost_run_reply, true)

    capture_log(fn ->
      assert {:error, :claim_pending, 30} = claim(context)
      [run] = FakePersistence.list_runs_for_issue("SYM-CLAIM")
      assert Ecto.UUID.cast(run.id) == {:ok, run.id}
      Application.delete_env(:symphony_elixir, :claim_test_lost_run_reply)
      retry_commit(context.manager)
      assignment = await_assignment(context.manager)
      assert assignment.run_id == run.id
      assert_single_assignment(context, assignment)
    end)
  end

  test "force stop reports an unresolved commit instead of falsely reporting no active work", context do
    Tracker.set_mode(:lost_reply)

    capture_log(fn ->
      assert {:error, :claim_pending, 30} = claim(context)

      assert %{status: "failed", cancelled: 0, failed: [%{reason: "claim_commit_pending"}]} =
               AssignmentManager.cancel_current("operator", context.manager)

      assert %{status: "no_active_assignment"} = AssignmentManager.cancel_current("operator", "other-project", context.manager)
      retry_commit(context.manager)
      assert_single_assignment(context, await_assignment(context.manager))
    end)
  end

  test "late results from cancelled preparation cannot publish work or crash its owner", context do
    owner = self()

    Application.put_env(:symphony_elixir, :claim_test_history_hook, fn ->
      send(owner, :history_waiting)
      receive do: (:release -> :ok)
    end)

    claimant = Task.async(fn -> claim(context) end)
    assert_receive :history_waiting, 2_000
    %{claim_task: job} = :sys.get_state(context.manager)
    assert %{status: "no_active_assignment"} = AssignmentManager.cancel_current("operator", context.manager)
    assert {:error, :claim_cancelled} = Task.await(claimant)
    send(context.manager, {job.ref, {:ok, %{}}})
    send(context.manager, {:DOWN, job.ref, :process, job.pid, :normal})
    assert AssignmentManager.current_assignment(context.manager) == nil
    assert Process.alive?(context.manager)
    assert FakePersistence.list_runs_for_issue("SYM-CLAIM") == []
  end

  test "database history timeout names the database stage and creates no run", context do
    :sys.replace_state(context.manager, &%{&1 | tracker_io_timeout_ms: 100})
    Application.put_env(:symphony_elixir, :claim_test_history_hook, fn -> receive do: (:release -> :ok) end)

    capture_log(fn ->
      assert {:error, {:claim_prepare_timeout, :candidate_history}, 30} = claim(context)
      assert FakePersistence.list_runs_for_issue("SYM-CLAIM") == []
      assert Tracker.updates() == 0
      assert :sys.get_state(context.manager).claim_task == nil
    end)
  end

  test "lost accepted-event response reuses the committed event", context do
    Application.put_env(:symphony_elixir, :claim_test_lost_event_reply, true)

    capture_log(fn ->
      assert {:error, :claim_pending, 30} = claim(context)
      [event] = FakePersistence.list_events(event_type: "task.accepted")
      Application.delete_env(:symphony_elixir, :claim_test_lost_event_reply)
      retry_commit(context.manager)
      assignment = await_assignment(context.manager)
      assert event.run_id == assignment.run_id
      assert FakePersistence.list_events(event_type: "task.accepted") == [event]
      assert_single_assignment(context, assignment)
    end)
  end

  test "stages distinguish tracker reads, history, and writes", context do
    log = capture_log(fn -> assert {:ok, _assignment} = claim(context) end)

    for stage <- ~w(candidate_fetch candidate_history issue_revalidation revalidation_history run_admission linear_transition accepted_event) do
      assert log =~ "stage=#{stage} status=completed elapsed_ms="
    end

    assert log =~ "phase=prepare"
    assert log =~ "phase=commit"
    assert log =~ "worker_session_id=#{context.session.id}"
  end

  test "null-project candidates without a fallback are typed rejections with no run", context do
    candidate = Tracker |> Agent.get(& &1.issue) |> Map.put(:project_slug, nil)
    Tracker.put_issue(candidate)

    log = capture_log(fn -> assert {:ok, {:empty, 5}} = claim(context) end)

    assert log =~ "event=admission_rejected"
    assert log =~ "issue_id=#{candidate.id}"
    assert log =~ "issue_identifier=#{candidate.identifier}"
    assert log =~ "context_source=nil"
    assert log =~ "reason=:missing_fallback_project"
    assert FakePersistence.list_runs_for_issue(candidate.identifier) == []
  end

  test "null-project candidates claim through the explicit fallback Symphony Project", context do
    Application.put_env(:symphony_elixir, :claim_test_fallback_project_slug, "fallback-project")
    candidate = Tracker |> Agent.get(& &1.issue) |> Map.put(:project_slug, nil)
    Tracker.put_issue(candidate)

    assert {:ok, assignment} = claim(context)
    assert assignment.project_id == "fake-project-id"
    persisted = FakePersistence.get_issue_by_identifier(candidate.identifier)
    assert persisted.snapshot["linear_project_slug"] == nil
    assert persisted.snapshot["symphony_project_slug"] == "fallback-project"
    assert persisted.snapshot["context_source"] == "fallback"
  end

  test "the query-state union cannot widen the resolved project's active-state admission", context do
    {:ok, loaded} = Workflow.load_example_package()

    workflows = [
      loaded |> Map.put(:project_id, "project-a") |> Map.put(:project_slug, "a") |> put_in([:config, "tracker", "project_slug"], "linear-a"),
      loaded |> Map.put(:project_id, "project-b") |> Map.put(:project_slug, "b") |> put_in([:config, "tracker"], %{"project_slug" => "linear-b", "active_states" => ["Todo"]})
    ]

    Application.put_env(:symphony_elixir, :claim_test_workflows, workflows)
    candidate = Tracker |> Agent.get(& &1.issue) |> Map.merge(%{project_slug: "linear-b", state: "Ready"})
    Tracker.put_issue(candidate)
    assert {:ok, {:empty, 5}} = claim(context)
    assert FakePersistence.list_runs_for_issue(candidate.identifier) == []

    Tracker.put_issue(%{candidate | state: "Todo"})
    assert {:ok, assignment} = claim(context)
    assert assignment.project_id == "project-b"
  end

  test "accepted claims persist the same project context in snapshot and event", context do
    assert {:ok, assignment} = claim(context)
    persisted = FakePersistence.get_issue_by_identifier("SYM-CLAIM")
    assert persisted.snapshot["symphony_project_slug"] == "fallback-project"
    assert persisted.snapshot["context_source"] == "linear_project"
    assert [%{payload: payload}] = FakePersistence.list_events(run_id: assignment.run_id, event_type: "task.accepted")
    assert payload["dispatch_context"]["symphony_project_id"] == "fake-project-id"
    assert payload["dispatch_context"]["context_source"] == "linear_project"
  end

  defp claim(context) do
    AssignmentManager.claim_with_policy(context.worker.id, context.session.id, %{"available_slots" => 1}, :listening_all, 1, context.manager)
  end

  defp retry_commit(manager) do
    %{claim_task: task} = :sys.get_state(manager)
    send(manager, {:retry_claim_commit, task.ref})
  end

  defp await_assignment(manager, attempts \\ 100)
  defp await_assignment(_manager, 0), do: flunk("claim did not publish an assignment")

  defp await_assignment(manager, attempts) do
    case AssignmentManager.current_assignment(manager) do
      nil ->
        Process.sleep(10)
        await_assignment(manager, attempts - 1)

      assignment ->
        assignment
    end
  end

  defp assert_single_assignment(context, assignment) do
    assert {:ok, ^assignment} = claim(context)
    assert [%{id: run_id}] = FakePersistence.list_runs_for_issue("SYM-CLAIM")
    assert run_id == assignment.run_id
    assert [%{run_id: ^run_id}] = FakePersistence.list_events(event_type: "task.accepted")
  end
end

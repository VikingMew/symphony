defmodule SymphonyElixir.WorkerTerminalOutcomeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixirWeb.WorkerApiController

  defmodule LinearClient do
    @moduledoc false

    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def graphql(query, variables) do
      cond do
        query =~ "SymphonyCreateComment" ->
          send(test_pid(), {:linear_comment, variables.issueId, variables.body})

          case Application.get_env(:symphony_elixir, :worker_terminal_linear_failure) do
            :comment -> {:error, :comment_down}
            _ -> {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
          end

        query =~ "SymphonyResolveStateId" ->
          send(test_pid(), {:linear_state_lookup, variables.issueId, variables.stateName})

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "team" => %{
                   "states" => %{"nodes" => [%{"id" => "state-blocked"}]}
                 }
               }
             }
           }}

        query =~ "SymphonyUpdateIssueState" ->
          send(test_pid(), {:linear_state_update, variables.issueId, variables.stateId})

          case Application.get_env(:symphony_elixir, :worker_terminal_linear_failure) do
            :transition -> {:error, :transition_down}
            _ -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
      end
    end

    defp test_pid do
      Application.fetch_env!(:symphony_elixir, :worker_terminal_outcome_test_pid)
    end
  end

  setup do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, LinearClient)
    Application.put_env(:symphony_elixir, :worker_terminal_outcome_test_pid, self())

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      Application.delete_env(:symphony_elixir, :worker_terminal_outcome_test_pid)
      Application.delete_env(:symphony_elixir, :worker_terminal_linear_failure)
    end)

    :ok
  end

  test "exhausted worker failures deliver blocker with the running issue project context" do
    {orchestrator, pid} = start_orchestrator(max_failure_retries: 1)
    {project_a, _project_b} = setup_multi_project_without_default()
    project_id = project_a.id
    assert {:error, :missing_project_context} = WorkflowStore.current()
    assert {:error, :missing_project_context} = Config.settings()

    issue_id = "issue-worker-failed-multi-project"
    identifier = "SYM-WORKER-FAILED-MULTI"
    put_persisted_issue(issue_id, identifier)

    put_running(pid, issue_id, identifier,
      retry_attempt: 0,
      run_id: "run-worker-failed-multi-1",
      project_id: project_id
    )

    Orchestrator.worker_task_finished(
      issue_id,
      {:failed, "transient worker failure"},
      orchestrator
    )

    first = :sys.get_state(pid)
    assert first.failure_counts == %{issue_id => 1}
    assert first.retry_attempts[issue_id].project_id == project_id

    put_running(pid, issue_id, identifier,
      retry_attempt: 1,
      run_id: "run-worker-failed-multi-2",
      project_id: project_id
    )

    Orchestrator.worker_task_finished(
      issue_id,
      {:failed, "persistent worker failure"},
      orchestrator
    )

    exhausted = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert exhausted.running == %{}
    assert exhausted.retry_attempts == %{}
    assert %{reason: "failure_retries_exhausted", project_id: ^project_id} = exhausted.blocked[issue_id]

    persisted = FakePersistence.get_issue_by_identifier(identifier)
    assert persisted.state == "Blocked"
    assert persisted.blocking_decision["comment_status"] == "completed"
    assert persisted.blocking_decision["transition_status"] == "completed"

    assert_receive {:linear_comment, ^issue_id, comment}
    assert comment =~ "failure_retries_exhausted"
    assert_receive {:linear_state_lookup, ^issue_id, "Blocked"}
    assert_receive {:linear_state_update, ^issue_id, "state-blocked"}
  end

  test "blocking delivery comment failures persist failed evidence without killing orchestrator" do
    {orchestrator, pid} = start_orchestrator(max_failure_retries: 0)
    {project_a, _project_b} = setup_multi_project_without_default()
    project_id = project_a.id
    Application.put_env(:symphony_elixir, :worker_terminal_linear_failure, :comment)
    assert {:error, :missing_project_context} = Config.settings()

    issue_id = "issue-worker-comment-failure"
    identifier = "SYM-WORKER-COMMENT-FAILURE"
    put_persisted_issue(issue_id, identifier)

    put_running(pid, issue_id, identifier,
      retry_attempt: 0,
      run_id: "run-worker-comment-failure",
      project_id: project_id
    )

    log =
      capture_log(fn ->
        Orchestrator.worker_task_finished(issue_id, {:failed, "persistent worker failure"}, orchestrator)
        state = :sys.get_state(pid)
        assert %{reason: "failure_retries_exhausted", project_id: ^project_id} = state.blocked[issue_id]
      end)

    assert Process.alive?(pid)
    persisted = FakePersistence.get_issue_by_identifier(identifier)
    assert persisted.state == "Blocked"
    assert persisted.blocking_decision["comment_status"] == %{"failed" => ":comment_down"}
    assert persisted.blocking_decision["transition_status"] == "completed"
    assert log =~ "Blocking decision delivery step failed"
    assert_receive {:linear_state_update, ^issue_id, "state-blocked"}
  end

  test "blocking delivery transition failures persist failed evidence without killing orchestrator" do
    {orchestrator, pid} = start_orchestrator(max_failure_retries: 0)
    {project_a, _project_b} = setup_multi_project_without_default()
    project_id = project_a.id
    Application.put_env(:symphony_elixir, :worker_terminal_linear_failure, :transition)
    assert {:error, :missing_project_context} = Config.settings()

    issue_id = "issue-worker-transition-failure"
    identifier = "SYM-WORKER-TRANSITION-FAILURE"
    put_persisted_issue(issue_id, identifier)

    put_running(pid, issue_id, identifier,
      retry_attempt: 0,
      run_id: "run-worker-transition-failure",
      project_id: project_id
    )

    log =
      capture_log(fn ->
        Orchestrator.worker_task_finished(issue_id, {:failed, "persistent worker failure"}, orchestrator)
        state = :sys.get_state(pid)

        assert %{reason: "failure_retries_exhausted", state: "In Progress", project_id: ^project_id} =
                 state.blocked[issue_id]
      end)

    assert Process.alive?(pid)
    persisted = FakePersistence.get_issue_by_identifier(identifier)
    assert persisted.state == "In Progress"
    assert persisted.blocking_decision["comment_status"] == "completed"
    assert persisted.blocking_decision["transition_status"] == %{"failed" => ":transition_down"}
    assert log =~ "Blocking decision delivery step failed"
    assert_receive {:linear_comment, ^issue_id, _comment}
  end

  test "blocking delivery workflow lookup failures persist failed evidence without killing orchestrator" do
    {orchestrator, pid} = start_orchestrator()
    setup_multi_project_without_default()
    assert {:error, :missing_project_context} = Config.settings()

    issue_id = "issue-worker-workflow-failure"
    identifier = "SYM-WORKER-WORKFLOW-FAILURE"
    put_persisted_issue(issue_id, identifier)

    put_running(pid, issue_id, identifier,
      retry_attempt: 0,
      run_id: "run-worker-workflow-failure",
      project_id: "missing-project"
    )

    log =
      capture_log(fn ->
        Orchestrator.worker_task_finished(issue_id, {:blocked, "operator blocker"}, orchestrator)
        state = :sys.get_state(pid)
        assert %{reason: "operator blocker", state: "In Progress", project_id: "missing-project"} = state.blocked[issue_id]
      end)

    assert Process.alive?(pid)
    persisted = FakePersistence.get_issue_by_identifier(identifier)
    assert persisted.state == "In Progress"
    assert %{"failed" => comment_failure} = persisted.blocking_decision["comment_status"]
    assert %{"failed" => transition_failure} = persisted.blocking_decision["transition_status"]
    assert comment_failure =~ "workflow_context_unavailable"
    assert transition_failure =~ "workflow_context_unavailable"
    assert log =~ "Blocking decision delivery step failed"
    refute_receive {:linear_comment, ^issue_id, _comment}, 100
    refute_receive {:linear_state_update, ^issue_id, _state_id}, 100
  end

  test "failed worker outcomes back off and exhaust the shared failure budget" do
    {orchestrator, pid} = start_orchestrator(max_failure_retries: 1)
    issue_id = "issue-worker-failed"
    identifier = "SYM-WORKER-FAILED"
    put_persisted_issue(issue_id, identifier)
    put_running(pid, issue_id, identifier, retry_attempt: 0, run_id: "run-worker-failed-1")

    Orchestrator.worker_task_finished(
      issue_id,
      {:failed, "transient worker failure"},
      orchestrator
    )

    first = :sys.get_state(pid)

    assert first.failure_counts == %{issue_id => 1}
    assert first.running == %{}

    assert %{
             attempt: 1,
             failure_count: 1,
             error: first_error,
             due_at_ms: due_at_ms
           } = first.retry_attempts[issue_id]

    assert first_error =~ "transient worker failure"
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)
    assert remaining_ms >= 9_500
    assert remaining_ms <= 10_500

    assert [
             %{
               issue_id: ^issue_id,
               identifier: ^identifier,
               attempt: 1,
               error: snapshot_error
             }
           ] = Orchestrator.snapshot(orchestrator, 100).retrying

    assert snapshot_error =~ "transient worker failure"

    put_running(pid, issue_id, identifier,
      retry_attempt: 1,
      run_id: "run-worker-failed-2"
    )

    Orchestrator.worker_task_finished(
      issue_id,
      {:failed, "persistent worker failure"},
      orchestrator
    )

    exhausted = :sys.get_state(pid)
    assert exhausted.running == %{}
    assert exhausted.retry_attempts == %{}
    assert %{reason: "failure_retries_exhausted"} = exhausted.blocked[issue_id]

    assert [
             %{
               issue_id: ^issue_id,
               identifier: ^identifier,
               run_id: "run-worker-failed-2",
               reason: "failure_retries_exhausted",
               detail: blocked_detail
             }
           ] = Orchestrator.snapshot(orchestrator, 100).blocked

    assert blocked_detail =~ "persistent worker failure"

    persisted = FakePersistence.get_issue_by_identifier(identifier)
    assert persisted.state == "Blocked"
    assert persisted.blocking_decision["reason"] == "failure_retries_exhausted"
    assert persisted.blocking_decision["evidence"] =~ "persistent worker failure"
    assert persisted.blocking_decision["evidence"] =~ "failure_attempt: 2"

    assert_receive {:linear_comment, ^issue_id, comment}
    assert comment =~ "failure_retries_exhausted"
    assert_receive {:linear_state_lookup, ^issue_id, "Blocked"}
    assert_receive {:linear_state_update, ^issue_id, "state-blocked"}
  end

  test "blocked worker outcomes persist and deliver immediately without entering the budget" do
    {orchestrator, pid} = start_orchestrator(max_failure_retries: 2)
    issue_id = "issue-worker-blocked"
    identifier = "SYM-WORKER-BLOCKED"
    reason = "handoff_failed\nopaque permission evidence"
    put_persisted_issue(issue_id, identifier)
    put_running(pid, issue_id, identifier, run_id: "run-worker-blocked")

    Orchestrator.worker_task_finished(issue_id, {:blocked, reason}, orchestrator)

    state = :sys.get_state(pid)
    assert state.failure_counts == %{}
    assert state.retry_attempts == %{}
    assert %{reason: ^reason, detail: ^reason} = state.blocked[issue_id]

    assert [
             %{
               issue_id: ^issue_id,
               identifier: ^identifier,
               run_id: "run-worker-blocked",
               reason: ^reason,
               detail: ^reason
             }
           ] = Orchestrator.snapshot(orchestrator, 100).blocked

    persisted = FakePersistence.get_issue_by_identifier(identifier)
    assert persisted.state == "Blocked"
    assert persisted.blocking_decision["reason"] == reason
    assert persisted.blocking_decision["evidence"] == reason

    assert_receive {:linear_comment, ^issue_id, comment}
    assert comment =~ "opaque permission evidence"
    assert_receive {:linear_state_lookup, ^issue_id, "Blocked"}
    assert_receive {:linear_state_update, ^issue_id, "state-blocked"}
  end

  test "blocked worker outcome without a running entry releases the claim" do
    {orchestrator, pid} = start_orchestrator()
    issue_id = "issue-worker-restarted"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.put(state.claimed, issue_id),
          failure_counts: Map.put(state.failure_counts, issue_id, 1)
      }
    end)

    Orchestrator.worker_task_finished(issue_id, {:blocked, "opaque blocker"}, orchestrator)

    state = :sys.get_state(pid)
    assert state.claimed == MapSet.new()
    assert state.failure_counts == %{}
    assert state.completed == MapSet.new([issue_id])
  end

  test "successful and cancelled worker outcomes clear their failure chains" do
    {orchestrator, pid} = start_orchestrator()
    success_id = "issue-worker-success"
    cancelled_id = "issue-worker-cancelled"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.new([success_id, cancelled_id]),
          failure_counts: %{success_id => 2, cancelled_id => 1}
      }
    end)

    Orchestrator.worker_task_finished(success_id, :success, orchestrator)
    Orchestrator.worker_task_finished(cancelled_id, :cancelled, orchestrator)

    state = :sys.get_state(pid)
    assert state.failure_counts == %{}
    assert state.claimed == MapSet.new()
    assert state.completed == MapSet.new([success_id, cancelled_id])
  end

  test "controller derives terminal outcomes from event type and summary only" do
    evidence = %{"reason" => "handoff_failed", "detail" => "opaque detail"}

    assert WorkerApiController.terminal_outcome("task.completed", %{}) == :success

    for success <- ["succeeded", "success"] do
      assert WorkerApiController.terminal_outcome(
               "task.failed",
               Map.put(evidence, "outcome", success)
             ) == :success
    end

    assert WorkerApiController.terminal_outcome(
             "task.cancelled",
             Map.put(evidence, "outcome", "cancelled")
           ) == :cancelled

    assert WorkerApiController.terminal_outcome(
             "task.failed",
             Map.put(evidence, "outcome", "blocked")
           ) == {:blocked, "handoff_failed\nopaque detail"}

    assert WorkerApiController.terminal_outcome(
             "task.failed",
             Map.put(evidence, "outcome", "failed")
           ) == {:failed, "handoff_failed\nopaque detail"}

    assert WorkerApiController.terminal_outcome("task.failed", evidence) ==
             {:failed, "handoff_failed\nopaque detail"}

    assert WorkerApiController.terminal_outcome(
             "task.failed",
             Map.put(evidence, "outcome", "unknown")
           ) == {:failed, "handoff_failed\nopaque detail"}
  end

  test "missing and unknown controller outcomes consume failure attempts" do
    {orchestrator, pid} = start_orchestrator(max_failure_retries: 2)

    outcomes = [
      {"issue-missing-outcome", "SYM-MISSING-OUTCOME", %{"reason" => "missing outcome"}},
      {"issue-unknown-outcome", "SYM-UNKNOWN-OUTCOME", %{"outcome" => "unknown", "reason" => "unknown outcome"}}
    ]

    Enum.each(outcomes, fn {issue_id, identifier, summary} ->
      put_persisted_issue(issue_id, identifier)
      put_running(pid, issue_id, identifier, run_id: "run-#{issue_id}")

      outcome = WorkerApiController.terminal_outcome("task.failed", summary)
      Orchestrator.worker_task_finished(issue_id, outcome, orchestrator)
    end)

    state = :sys.get_state(pid)

    assert state.failure_counts == %{
             "issue-missing-outcome" => 1,
             "issue-unknown-outcome" => 1
           }

    assert state.retry_attempts["issue-missing-outcome"].failure_count == 1
    assert state.retry_attempts["issue-unknown-outcome"].failure_count == 1
  end

  test "arbitrary agent update errors use the same retry budget without a reason whitelist" do
    {_orchestrator, pid} = start_orchestrator(max_failure_retries: 1)
    issue_id = "issue-agent-handoff-error"
    identifier = "SYM-AGENT-HANDOFF-ERROR"
    run_id = "run-agent-handoff-error"
    put_persisted_issue(issue_id, identifier)
    put_running(pid, issue_id, identifier, run_id: run_id)
    result = {:error, {:implementation_handoff_failed, :pull_request_conflict}}

    send(
      pid,
      {:linear_task_update_result, issue_id, result, %{}, %{}, "Ready to Merge"}
    )

    state = :sys.get_state(pid)
    assert state.failure_counts == %{issue_id => 1}
    assert state.running == %{}
    assert state.blocked == %{}
    assert state.retry_attempts[issue_id].failure_count == 1
    assert state.retry_attempts[issue_id].error =~ "pull_request_conflict"
  end

  defp start_orchestrator(overrides \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(), overrides)
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {name, pid}
  end

  defp setup_multi_project_without_default do
    {:ok, loaded} = Workflow.load()
    raw = Workflow.to_markdown(loaded.config, loaded.prompt)
    {:ok, project_a} = FakePersistence.default_project()

    FakePersistence.put_default_project_attrs!(%{
      linear_project_slug: "linear-a",
      repository_url: "git@example.test:a.git"
    })

    {:ok, _project_a_workflow} = FakePersistence.import_workflow(project_a, raw, "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@example.test:b.git",
        enabled: true
      })

    {:ok, _project_b_workflow} = FakePersistence.import_workflow(project_b, raw, "test")
    assert :ok = WorkflowStore.force_reload()
    assert MapSet.new(Enum.map(WorkflowStore.list_enabled(), & &1.project_id)) == MapSet.new([project_a.id, project_b.id])
    {project_a, project_b}
  end

  defp put_persisted_issue(issue_id, identifier) do
    current = FakePersistence.list_analytics_issues()

    FakePersistence.put_issues([
      %{
        identifier: identifier,
        tracker_issue_id: issue_id,
        state: "In Progress",
        blocking_decision: nil,
        no_progress_streak: 0
      }
      | current
    ])
  end

  defp put_running(pid, issue_id, identifier, opts) do
    issue = %Issue{
      id: issue_id,
      identifier: identifier,
      title: "Worker terminal outcome",
      state: "In Progress"
    }

    project_id = Keyword.get(opts, :project_id) || current_project_id()

    entry = %Orchestrator.RunningIssue{
      pid: self(),
      ref: make_ref(),
      run_id: Keyword.fetch!(opts, :run_id),
      identifier: identifier,
      issue: issue,
      project_id: project_id,
      session_id: "worker-session",
      retry_attempt: Keyword.get(opts, :retry_attempt, 0),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: Map.put(state.running, issue_id, entry),
          claimed: MapSet.put(state.claimed, issue_id)
      }
    end)
  end

  defp current_project_id do
    {:ok, %{project_id: project_id}} = WorkflowStore.current()
    project_id
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

defmodule SymphonyElixir.OrchestratorWorkspaceDiskGuardTest do
  use SymphonyElixir.TestSupport

  defmodule NotifyingAgentRunner do
    def run(issue, _recipient, _opts) do
      notify_and_wait({:issue_agent_started, issue.id, self()})
    end

    def run_operator(kind, run_id, _recipient, _opts) do
      notify_and_wait({:operator_runner_started, kind, run_id, self()})
    end

    defp notify_and_wait(message) do
      send(Application.fetch_env!(:symphony_elixir, :workspace_disk_guard_test_pid), message)

      receive do
        :finish -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defmodule StubLinearClient do
    def fetch_candidate_issues, do: {:ok, configured_issues()}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, configured_issues()}
    def fetch_issues_by_states(_states), do: {:ok, []}

    defp configured_issues do
      Application.get_env(:symphony_elixir, :workspace_disk_guard_test_issues, [])
    end
  end

  setup do
    keys = [
      :agent_runner_module,
      :linear_client_module,
      :workspace_disk_guard_test_issues,
      :workspace_disk_guard_test_pid
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})

    Application.put_env(:symphony_elixir, :agent_runner_module, NotifyingAgentRunner)
    Application.put_env(:symphony_elixir, :linear_client_module, StubLinearClient)
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_issues, [])
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_pid, self())

    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: "git@example.com:org/repo.git")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_app_env(key, value) end)
    end)

    :ok
  end

  test "a workspace readiness rejection skips issue dispatch without spawning an agent" do
    issue = issue("issue-readiness-rejected", "MT-238")
    issue_id = issue.id
    invalid_root = invalid_workspace_root!()

    {:ok, pid} = start_orchestrator(:IssueReadinessRejected)

    log =
      capture_log(fn ->
        dispatch_issue(pid, issue)
      end)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert state.blocked == %{}
    refute MapSet.member?(state.claimed, issue.id)
    refute_receive {:issue_agent_started, ^issue_id, _runner_pid}, 100

    assert log =~ "environment unavailable"
    assert log =~ "issue_id=#{issue.id}"
    assert log =~ "issue_identifier=#{issue.identifier}"
    assert log =~ "not_creatable"
    File.rm(invalid_root)
  end

  test "a workspace readiness rejection fails an operator task before run or agent start" do
    invalid_root = invalid_workspace_root!()
    {:ok, pid} = start_orchestrator(:OperatorReadinessRejected)

    reply = GenServer.call(pid, {:request_operator_task, :nap})

    assert reply.status == "failed"
    assert reply.accepted == false
    assert reply.failure_reason =~ "environment_unavailable"
    assert reply.failure_reason =~ "not_creatable"
    assert :sys.get_state(pid).running == %{}
    run_id = reply.run_id
    refute_receive {:operator_runner_started, :nap, ^run_id, _runner_pid}, 100
    File.rm(invalid_root)
  end

  test "workspace readiness recovery admits the same issue on a later poll" do
    issue = issue("issue-readiness-recovery", "MT-238-RECOVERY")
    issue_id = issue.id
    invalid_root = invalid_workspace_root!()

    {:ok, pid} = start_orchestrator(:IssueReadinessRecovers)
    dispatch_issue(pid, issue)

    state = :sys.get_state(pid)
    assert state.running == %{}
    refute_receive {:issue_agent_started, ^issue_id, _runner_pid}, 100

    File.rm!(invalid_root)
    File.mkdir_p!(invalid_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: invalid_root,
      project_repository_url: "git@example.com:org/repo.git"
    )

    dispatch_issue(pid, issue)

    assert_receive {:issue_agent_started, ^issue_id, runner_pid}, 500
    assert %Orchestrator.RunningIssue{} = :sys.get_state(pid).running[issue.id]
    send(runner_pid, :finish)
    File.rm_rf(invalid_root)
  end

  test "a normal disk guard allow proceeds with issue dispatch" do
    issue = issue("issue-disk-guard-allowed", "MT-238-ALLOWED")
    issue_id = issue.id
    {:ok, pid} = start_orchestrator(:IssueGuardAllows)
    dispatch_issue(pid, issue)

    assert_receive {:issue_agent_started, ^issue_id, runner_pid}, 500
    assert %Orchestrator.RunningIssue{} = :sys.get_state(pid).running[issue.id]
    assert Map.has_key?(:sys.get_state(pid).blocked, issue.id) == false

    send(runner_pid, :finish)
  end

  test "listening handlers return workspace preflight errors without changing listening state" do
    invalid_root = invalid_workspace_root!()
    {:ok, pid} = start_orchestrator(:ListeningReadinessRejected)
    before = :sys.get_state(pid)

    Enum.each([:start_listening, :start_refine_only_listening], fn request ->
      assert %{
               listening?: false,
               listening_mode: "not_listening",
               error: %{kind: :not_creatable, path: ^invalid_root}
             } = GenServer.call(pid, request)

      state = :sys.get_state(pid)
      assert state.listening_mode == :not_listening
      assert state.tick_timer_ref == before.tick_timer_ref
      assert state.tick_token == before.tick_token
    end)

    assert FakePersistence.list_events(event_type: "orchestrator.listening_started") == []
    File.rm(invalid_root)
  end

  test "worker-mode active retry releases ownership without reading the invalid Panel root" do
    previous_mode = Application.get_env(:symphony_elixir, :execution_mode)
    Application.put_env(:symphony_elixir, :execution_mode, :worker)
    on_exit(fn -> restore_app_env(:execution_mode, previous_mode) end)

    issue = issue("issue-worker-retry", "MT-WORKER-RETRY")
    invalid_root = invalid_workspace_root!()
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_issues, [issue])
    {:ok, workflow} = WorkflowStore.current()
    retry_token = make_ref()
    runs_before = FakePersistence.list_runs()

    {:ok, pid} =
      start_orchestrator(:WorkerRetry, worker_capacity_query: fn -> 1 end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | listening_mode: :listening_all,
          claimed: MapSet.put(state.claimed, issue.id),
          failure_counts: Map.put(state.failure_counts, issue.id, 2),
          retry_attempts: %{
            issue.id => %{
              attempt: 2,
              retry_token: retry_token,
              identifier: issue.identifier,
              project_id: workflow.project_id,
              failure_count: 2
            }
          }
      }
    end)

    send(pid, {:retry_issue, issue.id, retry_token})
    state = :sys.get_state(pid)

    assert state.max_concurrent_agents == 1
    refute MapSet.member?(state.claimed, issue.id)
    refute Map.has_key?(state.retry_attempts, issue.id)
    assert state.failure_counts[issue.id] == 2
    assert state.running == %{}
    assert FakePersistence.list_runs() == runs_before
    refute_receive {:issue_agent_started, _, _}, 100
    assert File.regular?(invalid_root)
    File.rm(invalid_root)
  end

  defp dispatch_issue(pid, issue) do
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_issues, [issue])

    :sys.replace_state(pid, fn state ->
      %{state | listening_mode: :listening_all}
    end)

    send(pid, :run_poll_cycle)
    _state = :sys.get_state(pid)
    :ok
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Disk guard",
      state: "In Progress",
      project_slug: SymphonyElixir.Config.settings!().tracker.project_slug
    }
  end

  defp invalid_workspace_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-invalid-workspace-#{System.unique_integer([:positive])}"
      )

    File.write!(root, "not a directory")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      project_repository_url: "git@example.com:org/repo.git"
    )

    root
  end

  defp start_orchestrator(suffix, opts \\ []) do
    orchestrator_name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(Keyword.put(opts, :name, orchestrator_name))

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {:ok, pid}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

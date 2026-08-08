defmodule SymphonyElixir.OrchestratorWorkspaceDiskGuardTest do
  use SymphonyElixir.TestSupport

  defmodule StubWorkspaceDiskGuard do
    def check(_settings) do
      case Application.fetch_env!(:symphony_elixir, :workspace_disk_guard_test_result) do
        :raise -> raise ArgumentError, "stubbed workspace disk guard failure"
        result -> result
      end
    end
  end

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
      :workspace_disk_guard_module,
      :workspace_disk_guard_test_issues,
      :workspace_disk_guard_test_pid,
      :workspace_disk_guard_test_result
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})

    Application.put_env(:symphony_elixir, :agent_runner_module, NotifyingAgentRunner)
    Application.put_env(:symphony_elixir, :linear_client_module, StubLinearClient)
    Application.put_env(:symphony_elixir, :workspace_disk_guard_module, StubWorkspaceDiskGuard)
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_issues, [])
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_pid, self())

    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: "git@example.com:org/repo.git")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_app_env(key, value) end)
    end)

    :ok
  end

  test "a disk guard exception blocks issue dispatch without spawning an agent" do
    issue = issue("issue-disk-guard-raise", "MT-238")
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_result, :raise)

    {:ok, pid} = start_orchestrator(:IssueGuardRaises)

    log =
      capture_log(fn ->
        dispatch_issue(pid, issue)
      end)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert %{reason: :workspace_disk_guard, detail: detail} = state.blocked[issue.id]
    assert detail =~ "disk_guard_evaluation_failed"
    assert detail =~ "stubbed workspace disk guard failure"
    refute_receive {:issue_agent_started, ^issue_id, _runner_pid}, 100

    assert log =~ "action=disk_guard_failed"
    assert log =~ "issue_id=#{issue.id}"
    assert log =~ "issue_identifier=#{issue.identifier}"
  end

  test "a disk guard exception fails an operator task without spawning an agent" do
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_result, :raise)
    {:ok, pid} = start_orchestrator(:OperatorGuardRaises)

    {reply, log} =
      with_log(fn ->
        GenServer.call(pid, {:request_operator_task, :nap})
      end)

    assert reply.status == "failed"
    assert reply.failure_reason =~ "disk_guard_evaluation_failed"
    assert reply.failure_reason =~ "stubbed workspace disk guard failure"
    assert :sys.get_state(pid).running == %{}
    run_id = reply.run_id
    refute_receive {:operator_runner_started, :nap, ^run_id, _runner_pid}, 100

    assert log =~ "action=disk_guard_failed"
    assert log =~ "run_id=#{reply.run_id}"
  end

  test "a normal disk guard denial keeps the existing blocked issue path" do
    issue = issue("issue-disk-guard-denied", "MT-238-DENIED")
    issue_id = issue.id

    Application.put_env(
      :symphony_elixir,
      :workspace_disk_guard_test_result,
      {:error,
       %{
         reason: :low_disk_space,
         root: "/tmp/workspaces",
         free_bytes: 99,
         min_free_bytes: 100,
         setting: "Settings / Workflow / Runtime / Minimum free GiB"
       }}
    )

    {:ok, pid} = start_orchestrator(:IssueGuardDenies)
    dispatch_issue(pid, issue)

    state = :sys.get_state(pid)
    assert state.running == %{}

    assert %{reason: :workspace_disk_guard, detail: detail} = state.blocked[issue.id]

    assert detail ==
             "low workspace disk space root=/tmp/workspaces free_bytes=99 min_free_bytes=100 setting=Settings / Workflow / Runtime / Minimum free GiB"

    refute_receive {:issue_agent_started, ^issue_id, _runner_pid}, 100
  end

  test "a normal disk guard allow proceeds with issue dispatch" do
    issue = issue("issue-disk-guard-allowed", "MT-238-ALLOWED")
    issue_id = issue.id
    Application.put_env(:symphony_elixir, :workspace_disk_guard_test_result, {:ok, %{free_bytes: 101}})

    {:ok, pid} = start_orchestrator(:IssueGuardAllows)
    dispatch_issue(pid, issue)

    assert_receive {:issue_agent_started, ^issue_id, runner_pid}, 500
    assert %Orchestrator.RunningIssue{} = :sys.get_state(pid).running[issue.id]
    refute Map.has_key?(:sys.get_state(pid).blocked, issue.id)

    send(runner_pid, :finish)
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
    %Issue{id: id, identifier: identifier, title: "Disk guard", state: "In Progress"}
  end

  defp start_orchestrator(suffix) do
    orchestrator_name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {:ok, pid}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

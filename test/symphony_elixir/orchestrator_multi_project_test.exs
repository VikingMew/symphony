defmodule SymphonyElixir.OrchestratorMultiProjectTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Orchestrator, Workflow, WorkflowStore}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.FakePersistence

  defmodule MultiProjectLinearClient do
    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_candidate_issues do
      slug = Config.settings!().tracker.project_slug
      send(test_pid(), {:candidate_fetch, slug})
      {:ok, Map.get(candidates(), slug, [])}
    end

    def fetch_issue_states_by_ids(ids) do
      issues = candidates() |> Map.values() |> List.flatten()
      {:ok, Enum.filter(issues, &(&1.id in ids))}
    end

    def graphql(_query, _variables), do: {:ok, %{"data" => %{}}}

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :multi_project_test_pid)
    defp candidates, do: Application.get_env(:symphony_elixir, :multi_project_candidates, %{})
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)

    Application.put_env(:symphony_elixir, :linear_client_module, MultiProjectLinearClient)
    Application.put_env(:symphony_elixir, :multi_project_test_pid, self())

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end

      Application.delete_env(:symphony_elixir, :multi_project_test_pid)
      Application.delete_env(:symphony_elixir, :multi_project_candidates)
    end)

    :ok
  end

  defp sample_workflow_markdown do
    Workflow.load()
    |> then(fn {:ok, workflow} -> Workflow.to_markdown(workflow.config, workflow.prompt) end)
  end

  test "poll cycle fetches candidates for every enabled project" do
    raw = sample_workflow_markdown()
    {:ok, project_a} = FakePersistence.default_project()

    FakePersistence.put_default_project_attrs!(%{
      repository_url: "git@github.com:VikingMew/project-a.git",
      linear_project_slug: "project"
    })

    {:ok, _} = FakePersistence.import_workflow(project_a, raw, "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@github.com:VikingMew/project-b.git",
        enabled: true
      })

    {:ok, _} = FakePersistence.import_workflow(project_b, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert length(WorkflowStore.list_enabled()) == 2

    orchestrator_name = Module.concat(__MODULE__, :PollOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    assert %{listening?: true} = GenServer.call(pid, :start_listening)
    send(pid, :run_poll_cycle)

    assert_receive {:candidate_fetch, "project"}, 2_000
    assert_receive {:candidate_fetch, "linear-b"}, 2_000
  end

  test "disabled project is not polled" do
    raw = sample_workflow_markdown()
    {:ok, project_a} = FakePersistence.default_project()

    FakePersistence.put_default_project_attrs!(%{
      repository_url: "git@github.com:VikingMew/project-a.git",
      linear_project_slug: "project"
    })

    {:ok, _} = FakePersistence.import_workflow(project_a, raw, "test")

    {:ok, _project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@github.com:VikingMew/project-b.git",
        enabled: false
      })

    assert :ok = WorkflowStore.force_reload()
    assert length(WorkflowStore.list_enabled()) == 1

    orchestrator_name = Module.concat(__MODULE__, :DisabledProjectOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    assert %{listening?: true} = GenServer.call(pid, :start_listening)
    send(pid, :run_poll_cycle)

    assert_receive {:candidate_fetch, "project"}, 2_000
    refute_receive {:candidate_fetch, "linear-b"}, 500
  end

  test "project-scoped rate-limit settings do not globally block dispatch" do
    {:ok, base} = Workflow.load()
    {:ok, project_a} = FakePersistence.default_project()

    FakePersistence.put_default_project_attrs!(%{
      repository_url: "git@github.com:VikingMew/project-a.git",
      linear_project_slug: "linear-a"
    })

    {:ok, _} =
      FakePersistence.import_workflow(
        project_a,
        workflow_markdown(base, "Project A", 5.0),
        "test"
      )

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@github.com:VikingMew/project-b.git",
        enabled: true
      })

    {:ok, _} =
      FakePersistence.import_workflow(
        project_b,
        workflow_markdown(base, "Project B", 3.0),
        "test"
      )

    assert :ok = WorkflowStore.force_reload()

    orchestrator_name = Module.concat(__MODULE__, :ProjectRateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | listening_mode: :listening_all,
          codex_rate_limits: %{
            "primary" => %{"window_duration_mins" => 300, "used_percent" => 96}
          }
      }
    end)

    send(pid, :run_poll_cycle)

    refute_receive {:candidate_fetch, "linear-a"}, 200
    assert_receive {:candidate_fetch, "linear-b"}, 2_000
  end

  test "worker kickoff renders the candidate project's persisted prompt" do
    previous_mode = Application.get_env(:symphony_elixir, :execution_mode)
    Application.put_env(:symphony_elixir, :execution_mode, :worker)
    on_exit(fn -> restore_app_env(:execution_mode, previous_mode) end)

    {:ok, base} = Workflow.load()
    {:ok, project_a} = FakePersistence.default_project()
    FakePersistence.put_default_project_attrs!(%{repository_url: "git@example.test:a.git", linear_project_slug: "linear-a"})
    {:ok, _} = FakePersistence.import_workflow(project_a, workflow_markdown(base, "Prompt A {{ issue.identifier }}", 5.0), "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@example.test:b.git",
        enabled: true
      })

    {:ok, _} = FakePersistence.import_workflow(project_b, workflow_markdown(base, "Prompt B {{ issue.identifier }}", 5.0), "test")
    {:ok, _worker} = FakePersistence.register_worker(%{"worker_name" => "worker-1", "total_slots" => 1})

    issue = %Issue{id: "issue-b", identifier: "B-1", title: "Run B", state: "Ready", labels: [], blocked_by: []}
    Application.put_env(:symphony_elixir, :multi_project_candidates, %{"linear-b" => [issue]})
    assert :ok = WorkflowStore.force_reload()

    pid = Process.whereis(Orchestrator)
    assert is_pid(pid)
    assert %{listening?: true} = Orchestrator.start_listening()
    on_exit(fn -> Orchestrator.stop_listening() end)
    send(pid, :run_poll_cycle)

    assert_eventually(fn ->
      case FakePersistence.list_tasks(project_id: project_b.id) do
        [%{payload: %{"prompt" => prompt}}] -> prompt =~ "Prompt B B-1"
        _ -> false
      end
    end)
  end

  defp workflow_markdown(base, prompt, threshold) do
    config = put_in(base.config, ["codex", "rate_limit_gate_5h_threshold_percent"], threshold)
    Workflow.to_markdown(config, prompt)
  end

  defp assert_eventually(fun, attempts \\ 40)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

defmodule SymphonyElixir.OrchestratorMultiProjectTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.{Config, Orchestrator, Workflow, WorkflowStore}

  defmodule MultiProjectLinearClient do
    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_candidate_issues do
      slug = Config.settings!().tracker.project_slug
      send(test_pid(), {:candidate_fetch, slug})
      {:ok, []}
    end

    def fetch_issue_states_by_ids(ids) do
      {:ok,
       Enum.map(ids, fn id ->
         %Issue{id: id, identifier: "MT-X", state: "In Progress", title: "X"}
       end)}
    end

    def graphql(_query, _variables), do: {:ok, %{"data" => %{}}}

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :multi_project_test_pid)
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
end

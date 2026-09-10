defmodule SymphonyElixir.DefaultProjectPlaceholderTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.{Orchestrator, Workflow, WorkflowStore}
  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule LinearClient do
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}
    def graphql(_query, _variables), do: {:ok, %{"data" => %{}}}
  end

  setup do
    previous_auth = Application.get_env(:symphony_elixir, :auth)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)

    Application.put_env(:symphony_elixir, :auth, enabled: false)
    Application.put_env(:symphony_elixir, :linear_client_module, LinearClient)

    on_exit(fn ->
      restore_app_env(:auth, previous_auth)
      restore_app_env(:linear_client_module, previous_client)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
    end)

    %{previous_endpoint: previous_endpoint}
  end

  test "control API starts listening with a default placeholder and a configured project", %{
    previous_endpoint: previous_endpoint
  } do
    configured_project = seed_default_placeholder_with_configured_project!()
    orchestrator = Module.concat(__MODULE__, :ApiOrchestrator)

    endpoint_config =
      Keyword.merge(previous_endpoint,
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator
      )

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    start_orchestrator!(orchestrator)

    assert [%{project_id: project_id}] = WorkflowStore.list_enabled()
    assert project_id == configured_project.id

    assert %{"listening_mode" => "listening_all"} =
             build_conn()
             |> post("/api/v1/control/listening", %{mode: "all"})
             |> json_response(200)

    assert %{"polling" => %{"listening_mode" => "listening_all"}} =
             build_conn()
             |> get("/api/v1/state")
             |> json_response(200)
  end

  test "real enabled project without repository URL still blocks listening" do
    seed_project_without_repository_url!()
    orchestrator = Module.concat(__MODULE__, :MissingRepositoryOrchestrator)
    start_orchestrator!(orchestrator)

    assert %{error: ":missing_project_repository_url", listening?: false, listening_mode: "not_listening"} =
             GenServer.call(orchestrator, :start_listening)
  end

  defp seed_default_placeholder_with_configured_project! do
    raw = sample_workflow_markdown()
    {:ok, fixture_project} = FakePersistence.update_project("fake-project-id", %{enabled: false})
    {:ok, _fixture_workflow} = FakePersistence.import_workflow(fixture_project, raw, "test")

    {:ok, placeholder} =
      FakePersistence.create_project(%{
        name: "Default",
        slug: "default",
        linear_project_slug: "project",
        repository_url: nil,
        enabled: true
      })

    {:ok, _placeholder_workflow} = FakePersistence.import_workflow(placeholder, raw, "test")

    {:ok, configured_project} =
      FakePersistence.create_project(%{
        name: "Configured Project",
        slug: "configured",
        linear_project_slug: "configured-linear",
        repository_url: "git@example.test:configured.git",
        enabled: true
      })

    {:ok, _configured_workflow} = FakePersistence.import_workflow(configured_project, raw, "test")
    assert :ok = WorkflowStore.force_reload()
    configured_project
  end

  defp seed_project_without_repository_url! do
    raw = sample_workflow_markdown()
    {:ok, project} = FakePersistence.default_project()

    {:ok, _project} =
      FakePersistence.update_project(project.id, %{
        linear_project_slug: "project",
        repository_url: nil,
        enabled: true
      })

    {:ok, _workflow} = FakePersistence.import_workflow(project, raw, "test")
    assert :ok = WorkflowStore.force_reload()
  end

  defp sample_workflow_markdown do
    Workflow.load()
    |> then(fn {:ok, workflow} -> Workflow.to_markdown(workflow.config, workflow.prompt) end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_orchestrator!(name) do
    start_supervised!(%{
      id: name,
      start: {Orchestrator, :start_link, [[name: name]]}
    })
  end
end

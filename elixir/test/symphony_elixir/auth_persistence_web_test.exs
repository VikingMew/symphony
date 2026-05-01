defmodule SymphonyElixir.AuthPersistenceWebTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_session: 2]

  alias SymphonyElixir.{Auth, Persistence, Workflow}
  alias SymphonyElixir.Persistence.{Project, WorkflowVersion}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous_auth = Application.get_env(:symphony_elixir, :auth)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)

    on_exit(fn ->
      restore_app_env(:auth, previous_auth)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "password hashes verify and reject invalid passwords" do
    hash = Auth.hash_password("correct horse")

    assert hash =~ "pbkdf2_sha256$"
    assert Auth.verify("correct horse", hash)
    refute Auth.verify("wrong", hash)
    refute Auth.verify("correct horse", "plaintext")
  end

  test "browser and api routes require auth when enabled" do
    Application.put_env(:symphony_elixir, :auth,
      enabled: true,
      username: "admin",
      password_hash: Auth.hash_password("secret")
    )

    start_test_endpoint()

    conn = get(build_conn(), "/")
    assert redirected_to(conn) == "/login"

    assert %{"error" => %{"code" => "authentication_required"}} =
             build_conn()
             |> get("/api/v1/state")
             |> json_response(401)
  end

  test "valid login creates a session and logout clears it" do
    Application.put_env(:symphony_elixir, :auth,
      enabled: true,
      username: "admin",
      password_hash: Auth.hash_password("secret")
    )

    start_test_endpoint()

    conn =
      build_conn()
      |> init_test_session(%{})
      |> post("/login", %{"username" => "admin", "password" => "secret"})

    assert redirected_to(conn) == "/"
    assert get_session(conn, :symphony_user) == "admin"

    conn = delete(conn, "/logout")
    assert redirected_to(conn) == "/login"

    conn = conn |> recycle() |> get("/")
    assert redirected_to(conn) == "/login"
  end

  test "workflow versions preserve raw workflow and parsed fields" do
    {:ok, project} =
      Persistence.create_project(%{
        name: "Workflow Test #{System.unique_integer([:positive])}",
        slug: "workflow-test-#{System.unique_integer([:positive])}"
      })

    raw = File.read!(Workflow.workflow_file_path())

    assert {:ok, %WorkflowVersion{} = version} = Persistence.import_workflow(project, raw, "test")
    assert version.active
    assert version.raw_workflow_md == raw
    assert version.prompt_body =~ "You are an agent"
    assert get_in(version.yaml_config, ["tracker", "kind"]) == "linear"
    assert Persistence.export_workflow(version) == raw
  end

  test "workflow store can load active workflow from database when explicitly enabled" do
    previous_source = Application.get_env(:symphony_elixir, :workflow_source)

    on_exit(fn -> restore_app_env(:workflow_source, previous_source) end)

    {:ok, project} = Persistence.default_project()

    raw = File.read!(Workflow.workflow_file_path()) |> String.replace("You are an agent", "You are a database agent")
    assert {:ok, _version} = Persistence.import_workflow(project, raw, "test")

    Application.put_env(:symphony_elixir, :workflow_source, :database)

    assert {:ok, workflow} = SymphonyElixir.WorkflowStore.current()
    assert workflow.prompt =~ "database agent"
    assert is_binary(workflow.workflow_version_id)
  end

  test "invalid workflow is rejected before activation" do
    {:ok, project} =
      Persistence.create_project(%{
        name: "Invalid Workflow #{System.unique_integer([:positive])}",
        slug: "invalid-workflow-#{System.unique_integer([:positive])}"
      })

    assert {:error, _reason} = Persistence.import_workflow(project, "---\ntracker: [bad\n---\nPrompt", "test")
  end

  test "admin workflow page saves raw workflow and lists versions" do
    start_test_endpoint()
    raw = File.read!(Workflow.workflow_file_path())

    {:ok, view, html} = live(build_conn(), "/workflows")
    assert html =~ "Raw WORKFLOW.md"

    html =
      view
      |> form("form", workflow: %{raw: raw})
      |> render_submit()

    assert html =~ "Version History"
  end

  test "projects and runs pages render persisted data" do
    {:ok, %Project{} = project} =
      Persistence.create_project(%{
        name: "UI Project #{System.unique_integer([:positive])}",
        slug: "ui-project-#{System.unique_integer([:positive])}"
      })

    {:ok, run} =
      Persistence.create_run(%{
        project_id: project.id,
        issue_identifier: "UI-1",
        status: "running",
        attempt: 0
      })

    assert {:ok, _event} =
             Persistence.record_event(%{
               project_id: project.id,
               run_id: run.id,
               issue_identifier: "UI-1",
               event_type: "run.started",
               payload: %{"source" => "test"}
             })

    start_test_endpoint()

    {:ok, _view, projects_html} = live(build_conn(), "/projects")
    assert projects_html =~ project.name

    {:ok, _view, runs_html} = live(build_conn(), "/runs")
    assert runs_html =~ "UI-1"
    assert runs_html =~ "running"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

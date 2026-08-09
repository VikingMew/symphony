defmodule SymphonyElixir.Persistence.WorkflowStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.{Persistence, Repo}
  alias SymphonyElixir.Persistence.Project
  alias SymphonyElixir.Persistence.WorkflowStore
  alias SymphonyElixir.Persistence.WorkflowVersion

  setup do
    previous_allow_test_source = Application.get_env(:symphony_elixir, :allow_test_workflow_source)

    on_exit(fn ->
      restore_app_env(:allow_test_workflow_source, previous_allow_test_source)
    end)
  end

  test "project and workflow lookups tolerate an unavailable Repo" do
    refute Process.whereis(SymphonyElixir.Repo)

    assert WorkflowStore.default_project() == {:error, :repo_unavailable}
    assert WorkflowStore.list_projects() == []
    assert WorkflowStore.create_project(%{}) == {:error, :repo_unavailable}
    assert WorkflowStore.update_project("project-id", %{}) == {:error, :repo_unavailable}
    assert WorkflowStore.active_workflow_version() == nil
    assert WorkflowStore.list_workflow_versions() == []
  end

  test "project and workflow query faults are logged and reraised" do
    _pid = start_repo_stub!()
    project = %Project{id: "project-id"}

    log =
      capture_log(fn ->
        assert_raise ArgumentError, fn -> WorkflowStore.default_project() end
        assert_raise ArgumentError, fn -> WorkflowStore.list_projects() end
        assert_raise ArgumentError, fn -> WorkflowStore.active_workflow_version(project) end
        assert_raise ArgumentError, fn -> WorkflowStore.list_workflow_versions(project) end
      end)

    assert log =~ "Workflow persistence query failed operation=default_project outcome=failed"
    assert log =~ "Workflow persistence query failed operation=list_projects outcome=failed"
    assert log =~ "Workflow persistence query failed operation=active_workflow_version outcome=failed"
    assert log =~ "Workflow persistence query failed operation=list_workflow_versions outcome=failed"
  end

  test "default_project is a pure query when no default row exists" do
    with_repo(fn ->
      assert WorkflowStore.default_project() == {:error, :not_found}
      assert Repo.aggregate(Project, :count) == 0
      assert WorkflowStore.active_workflow_version() == nil
    end)
  end

  test "active_workflow_version uses the first enabled project when no default row exists" do
    with_repo(fn ->
      {:ok, alpha} = WorkflowStore.create_project(%{name: "Alpha", slug: "alpha", enabled: true})
      {:ok, beta} = WorkflowStore.create_project(%{name: "Beta", slug: "beta", enabled: true})
      alpha_version = insert_workflow_version!(alpha, "Alpha prompt")
      _beta_version = insert_workflow_version!(beta, "Beta prompt")

      assert WorkflowStore.default_project() == {:error, :not_found}
      assert WorkflowStore.active_workflow_version().id == alpha_version.id
    end)
  end

  test "workflow_to_loaded returns runtime shape without a Repo-backed project overlay" do
    version = %WorkflowVersion{
      id: "workflow-version-id",
      project_id: nil,
      yaml_config: %{"tracker" => %{"kind" => "linear"}},
      prompt_body: "Base prompt"
    }

    assert WorkflowStore.workflow_to_loaded(version) == %{
             config: %{"tracker" => %{"kind" => "linear"}},
             prompt: "Base prompt",
             prompt_template: "Base prompt",
             workflow_version_id: "workflow-version-id",
             project_id: nil
           }
  end

  test "export_workflow prefers raw markdown and can render stored YAML plus prompt" do
    assert WorkflowStore.export_workflow(%WorkflowVersion{raw_workflow_md: "raw workflow"}) == "raw workflow"

    rendered =
      WorkflowStore.export_workflow(%WorkflowVersion{
        yaml_config: %{"tracker" => %{"kind" => "linear"}},
        prompt_body: "Rendered prompt"
      })

    assert rendered =~ "tracker:"
    assert rendered =~ "Rendered prompt"
  end

  test "test workflow source activation is blocked when explicitly disabled" do
    Application.put_env(:symphony_elixir, :allow_test_workflow_source, false)

    assert WorkflowStore.activate_workflow_version(%WorkflowVersion{source: "test"}) ==
             {:error, :test_workflow_source_not_allowed}
  end

  test "public persistence context delegates workflow store compatibility functions" do
    version = %WorkflowVersion{raw_workflow_md: "raw workflow"}

    assert Persistence.default_project() == WorkflowStore.default_project()
    assert Persistence.list_projects() == {:error, :repo_unavailable}
    assert WorkflowStore.list_projects() == []
    assert Persistence.active_workflow_version() == WorkflowStore.active_workflow_version()
    assert Persistence.list_workflow_versions() == WorkflowStore.list_workflow_versions()
    assert Persistence.export_workflow(version) == WorkflowStore.export_workflow(version)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_repo_stub! do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    true = Process.register(pid, SymphonyElixir.Repo)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp insert_workflow_version!(project, prompt) do
    %WorkflowVersion{}
    |> WorkflowVersion.changeset(%{
      project_id: project.id,
      version: 1,
      raw_workflow_md: prompt,
      yaml_config: %{},
      prompt_body: prompt,
      source: "manual",
      active: true
    })
    |> Repo.insert!()
  end

  defp with_repo(fun) do
    previous_config = Application.fetch_env!(:symphony_elixir, Repo)
    database = Path.join(System.tmp_dir!(), "exec-plan-250-workflow-store-#{System.unique_integer([:positive])}.db")

    Application.put_env(
      :symphony_elixir,
      Repo,
      previous_config |> Keyword.put(:database, database) |> Keyword.put(:pool_size, 1)
    )

    try do
      {:ok, repo} = Repo.start_link()

      try do
        create_workflow_store_schema!()
        fun.()
      after
        Supervisor.stop(repo)
      end
    after
      Application.put_env(:symphony_elixir, Repo, previous_config)
      Enum.each([database, database <> "-wal", database <> "-shm"], &File.rm/1)
    end
  end

  defp create_workflow_store_schema! do
    SQL.query!(Repo, """
    CREATE TABLE projects (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      slug TEXT NOT NULL,
      linear_project_slug TEXT,
      repository_url TEXT,
      default_branch TEXT NOT NULL DEFAULT 'main',
      checkout_depth INTEGER NOT NULL DEFAULT 1,
      source_strategy TEXT NOT NULL DEFAULT 'clone',
      worktree_fetch INTEGER NOT NULL DEFAULT 1,
      worktree_cleanup INTEGER NOT NULL DEFAULT 1,
      description TEXT,
      enabled INTEGER NOT NULL DEFAULT 1,
      after_create_hook TEXT,
      before_run_hook TEXT,
      after_run_hook TEXT,
      before_remove_hook TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    SQL.query!(Repo, "CREATE UNIQUE INDEX projects_slug_index ON projects (slug)")

    SQL.query!(Repo, """
    CREATE TABLE workflow_versions (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      version INTEGER NOT NULL,
      raw_workflow_md TEXT NOT NULL,
      yaml_config TEXT NOT NULL DEFAULT '{}',
      prompt_body TEXT NOT NULL,
      source TEXT NOT NULL DEFAULT 'manual',
      active INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end

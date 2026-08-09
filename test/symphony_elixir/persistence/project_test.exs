defmodule SymphonyElixir.Persistence.ProjectTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.{Persistence, Repo}
  alias SymphonyElixir.Persistence.{Project, WorkflowStore}

  test "delete_project returns repo unavailable when persistence is stopped" do
    refute Process.whereis(Repo)
    assert Persistence.delete_project("project-id") == {:error, :repo_unavailable}
  end

  test "delete_project removes a project without dependencies" do
    with_repo(fn ->
      {:ok, project} = WorkflowStore.create_project(%{name: "Standalone", slug: "standalone"})

      assert {:ok, deleted_project} = Persistence.delete_project(project.id)
      assert deleted_project.id == project.id
      assert Repo.get(Project, project.id) == nil
    end)
  end

  test "delete_project cascades workflows and detaches run issue and task history" do
    with_repo(fn ->
      {:ok, project} = WorkflowStore.create_project(%{name: "Owned", slug: "owned"})
      insert_reference!("workflow_versions", "workflow-version-id", project.id)
      insert_reference!("runs", "run-id", project.id)
      insert_reference!("issues", "issue-id", project.id)
      insert_reference!("tasks", "task-id", project.id)

      assert {:ok, deleted_project} = Persistence.delete_project(project)
      assert deleted_project.id == project.id
      assert Repo.get(Project, project.id) == nil
      assert row_count("workflow_versions") == 0
      assert project_id("runs", "run-id") == nil
      assert project_id("issues", "issue-id") == nil
      assert project_id("tasks", "task-id") == nil
    end)
  end

  defp insert_reference!(table, id, project_id) when table in ~w(workflow_versions runs issues tasks) do
    SQL.query!(Repo, "INSERT INTO #{table} (id, project_id) VALUES (?, ?)", [id, project_id])
  end

  defp row_count(table) when table in ~w(workflow_versions runs issues tasks) do
    %{rows: [[count]]} = SQL.query!(Repo, "SELECT COUNT(*) FROM #{table}")
    count
  end

  defp project_id(table, id) when table in ~w(runs issues tasks) do
    %{rows: [[project_id]]} = SQL.query!(Repo, "SELECT project_id FROM #{table} WHERE id = ?", [id])
    project_id
  end

  defp with_repo(fun) do
    previous_config = Application.fetch_env!(:symphony_elixir, Repo)
    database = Path.join(System.tmp_dir!(), "exec-plan-252-project-#{System.unique_integer([:positive])}.db")

    Application.put_env(
      :symphony_elixir,
      Repo,
      previous_config |> Keyword.put(:database, database) |> Keyword.put(:pool_size, 1)
    )

    try do
      {:ok, repo} = Repo.start_link()

      try do
        create_schema!()
        fun.()
      after
        Supervisor.stop(repo)
      end
    after
      Application.put_env(:symphony_elixir, Repo, previous_config)
      Enum.each([database, database <> "-wal", database <> "-shm"], &File.rm/1)
    end
  end

  defp create_schema! do
    SQL.query!(Repo, "PRAGMA foreign_keys = ON")

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
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE
    )
    """)

    Enum.each(~w(runs issues tasks), fn table ->
      SQL.query!(Repo, """
      CREATE TABLE #{table} (
        id TEXT PRIMARY KEY,
        project_id TEXT REFERENCES projects(id) ON DELETE NO ACTION
      )
      """)
    end)
  end
end

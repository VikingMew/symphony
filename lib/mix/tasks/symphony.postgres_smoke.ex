defmodule Mix.Tasks.Symphony.PostgresSmoke do
  @moduledoc """
  Runs the opt-in PostgreSQL migration, SQLite cutover, persistence, and
  concurrent-write smoke test against an isolated empty database.
  """

  use Mix.Task

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.{Persistence, Repo, SQLiteImporter}
  alias SymphonyElixir.Persistence.{EventRecord, Project, WorkflowStore}

  @shortdoc "Runs the explicit PostgreSQL integration smoke test"
  @requirements ["app.config"]

  @project_id "10000000-0000-0000-0000-000000000001"
  @workflow_id "20000000-0000-0000-0000-000000000001"
  @issue_id "30000000-0000-0000-0000-000000000001"
  @run_id "40000000-0000-0000-0000-000000000001"
  @worker_id "50000000-0000-0000-0000-000000000001"
  @session_id "60000000-0000-0000-0000-000000000001"
  @task_id "70000000-0000-0000-0000-000000000001"
  @lease_id "80000000-0000-0000-0000-000000000001"
  @timestamp "2026-08-27T10:00:00.000000Z"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]) do
    sqlite_path = Path.join(System.tmp_dir!(), "symphony-pg-smoke-#{System.unique_integer([:positive])}.db")

    try do
      create_sqlite_fixture!(sqlite_path)
      migrate_and_rebuild!()

      counts = import_and_exercise!(sqlite_path)

      Enum.each(SQLiteImporter.app_tables(), fn table ->
        Mix.shell().info("smoke verified table=#{table} rows=#{Map.fetch!(counts, table)}")
      end)

      Mix.shell().info("smoke concurrent_event_writes=200 post_write=usable result=PASS")
      :ok
    after
      File.rm(sqlite_path)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix symphony.postgres_smoke")

  defp migrate_and_rebuild! do
    case SymphonyElixir.Release.migrate() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(SymphonyElixir.DatabaseSetup.format_error(reason))
    end

    with_repo!(fn repo ->
      migrations_path = :symphony_elixir |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")
      Ecto.Migrator.run(repo, migrations_path, :down, all: true)
      Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      verify_postgres_schema!(repo)
      verify_bootstrap_concurrency!()
    end)
  end

  defp verify_bootstrap_concurrency! do
    results =
      1..20
      |> Task.async_stream(
        fn _index -> WorkflowStore.default_project() end,
        max_concurrency: 20,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    1 = Enum.count(results, &match?({:ok, %Project{}}, &1))
    19 = Enum.count(results, &match?({:error, :not_found}, &1))
    1 = Repo.aggregate(Project, :count)

    %Project{} = project = Repo.get_by!(Project, slug: "default")
    Repo.delete!(project)
    0 = Repo.aggregate(Project, :count)
  end

  defp import_and_exercise!(sqlite_path) do
    with_repo!(fn repo ->
      {:ok, counts} = SQLiteImporter.import_backup(repo, sqlite_path)
      assert_imported_relationships!(repo)

      {:error, {:target_not_empty, _counts}} = SQLiteImporter.import_backup(repo, sqlite_path)

      {:ok, project} = WorkflowStore.create_project(%{name: "Smoke Project", slug: "smoke-project"})

      {:ok, issue} =
        Persistence.upsert_issue(%{
          project_id: project.id,
          identifier: "SMOKE-1",
          title: "PostgreSQL smoke"
        })

      {:ok, run} =
        Persistence.create_run(%{
          project_id: project.id,
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          status: "running"
        })

      {:ok, task} = Persistence.enqueue_task(%{project_id: project.id, run_id: run.id})
      true = task.project_id == project.id

      concurrent_event_writes!(project.id, run.id)

      {:ok, marker} =
        Persistence.record_event(%{
          project_id: project.id,
          run_id: run.id,
          issue_identifier: issue.identifier,
          event_type: "smoke.persistence_usable",
          payload: %{"after_concurrency" => true}
        })

      %EventRecord{event_type: "smoke.persistence_usable"} = Repo.get!(EventRecord, marker.id)
      counts
    end)
  end

  defp concurrent_event_writes!(project_id, run_id) do
    1..200
    |> Task.async_stream(
      fn index ->
        Persistence.record_event(%{
          project_id: project_id,
          run_id: run_id,
          issue_identifier: "SMOKE-1",
          event_type: "smoke.concurrent",
          payload: %{"index" => index}
        })
      end,
      max_concurrency: 20,
      timeout: 30_000,
      ordered: false
    )
    |> Enum.each(fn
      {:ok, {:ok, %EventRecord{}}} -> :ok
      result -> Mix.raise("Concurrent PostgreSQL event write failed: #{inspect(result)}")
    end)

    %{rows: [[200]]} =
      SQL.query!(Repo, "SELECT COUNT(*) FROM events WHERE event_type = 'smoke.concurrent'", [])
  end

  defp verify_postgres_schema!(repo) do
    %{rows: [["uuid"], ["jsonb"], ["timestamp without time zone"]]} =
      SQL.query!(
        repo,
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND (table_name, column_name) IN (
            ('projects', 'id'),
            ('workflows', 'yaml_config'),
            ('events', 'occurred_at')
          )
        ORDER BY CASE column_name
          WHEN 'id' THEN 1
          WHEN 'yaml_config' THEN 2
          ELSE 3
        END
        """,
        []
      )

    %{rows: [[foreign_keys]]} =
      SQL.query!(repo, "SELECT COUNT(*) FROM pg_constraint WHERE contype = 'f' AND connamespace = 'public'::regnamespace", [])

    if foreign_keys < 10, do: Mix.raise("Expected PostgreSQL foreign keys, found #{foreign_keys}")

    %{rows: [[indexes]]} =
      SQL.query!(repo, "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname <> 'schema_migrations_pkey'", [])

    if indexes < 20, do: Mix.raise("Expected PostgreSQL indexes, found #{indexes}")
  end

  defp assert_imported_relationships!(repo) do
    %{rows: [[@project_id, @workflow_id]]} =
      SQL.query!(
        repo,
        """
        SELECT p.id::text, w.id::text
        FROM projects p
        JOIN workflows w ON w.project_id = p.id
        WHERE p.id = $1::text::uuid
        """,
        [@project_id]
      )

    %{rows: [[@run_id, @issue_id]]} =
      SQL.query!(repo, "SELECT id::text, issue_id::text FROM runs WHERE id = $1::text::uuid", [@run_id])

    %{rows: [[@lease_id, @task_id, @worker_id, @session_id]]} =
      SQL.query!(
        repo,
        "SELECT id::text, task_id::text, worker_id::text, worker_session_id::text FROM task_leases WHERE id = $1::text::uuid",
        [@lease_id]
      )
  end

  defp with_repo!(fun) do
    case Ecto.Migrator.with_repo(Repo, fun) do
      {:ok, result, _apps} -> result
      {:error, reason} -> Mix.raise("PostgreSQL smoke connection failed: #{inspect(reason)}")
    end
  end

  defp create_sqlite_fixture!(path) do
    sqlite3 = System.find_executable("sqlite3") || Mix.raise("sqlite3 is required for the PostgreSQL smoke test")

    case System.cmd(sqlite3, [path, sqlite_fixture_sql()], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("Failed to create SQLite smoke fixture: exit=#{status} output=#{output}")
    end
  end

  defp sqlite_fixture_sql do
    """
    PRAGMA foreign_keys = ON;
    CREATE TABLE users (id TEXT, username TEXT, password_hash TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE projects (id TEXT, name TEXT, slug TEXT, description TEXT, enabled INTEGER, linear_project_slug TEXT, repository_url TEXT, default_branch TEXT, checkout_depth INTEGER, source_strategy TEXT, worktree_fetch INTEGER, worktree_cleanup INTEGER, after_create_hook TEXT, before_run_hook TEXT, after_run_hook TEXT, before_remove_hook TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE tracker_configs (id TEXT, project_id TEXT, kind TEXT, endpoint TEXT, project_slug TEXT, api_key_secret_ref TEXT, active_states TEXT, terminal_states TEXT, enabled INTEGER, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE workflow_versions (id TEXT, project_id TEXT, version INTEGER, raw_workflow_md TEXT, yaml_config TEXT, prompt_body TEXT, source TEXT, active INTEGER, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE issues (id TEXT, project_id TEXT, tracker_issue_id TEXT, identifier TEXT, title TEXT, state TEXT, url TEXT, labels TEXT, snapshot TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE runs (id TEXT, project_id TEXT, workflow_version_id TEXT, issue_id TEXT, issue_identifier TEXT, workspace_path TEXT, status TEXT, attempt INTEGER, failure_reason TEXT, started_at TEXT, finished_at TEXT, inserted_at TEXT, updated_at TEXT, execution_mode TEXT, kind TEXT, profile TEXT, label TEXT);
    CREATE TABLE agent_turns (id TEXT, run_id TEXT, turn_index INTEGER, status TEXT, summary TEXT, started_at TEXT, finished_at TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE workspaces (id TEXT, project_id TEXT, issue_identifier TEXT, path TEXT, host TEXT, status TEXT, created_at TEXT, cleaned_at TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE events (id TEXT, project_id TEXT, run_id TEXT, issue_identifier TEXT, event_type TEXT, payload TEXT, occurred_at TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE app_settings (key TEXT, value TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE workers (id TEXT, name TEXT, status TEXT, labels TEXT, capabilities TEXT, credential_ref TEXT, last_seen_at TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE worker_sessions (id TEXT, worker_id TEXT, protocol_version TEXT, worker_version TEXT, instance_id TEXT, total_slots INTEGER, connected_at TEXT, last_heartbeat_at TEXT, disconnected_at TEXT, status TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE tasks (id TEXT, project_id TEXT, run_id TEXT, workflow_version_id TEXT, issue_identifier TEXT, status TEXT, priority INTEGER, execution_mode TEXT, required_capabilities TEXT, payload TEXT, queued_at TEXT, started_at TEXT, finished_at TEXT, inserted_at TEXT, updated_at TEXT);
    CREATE TABLE task_leases (id TEXT, task_id TEXT, worker_id TEXT, worker_session_id TEXT, status TEXT, attempt INTEGER, expires_at TEXT, acquired_at TEXT, released_at TEXT, inserted_at TEXT, updated_at TEXT);

    INSERT INTO users VALUES ('90000000-0000-0000-0000-000000000001', 'smoke', 'hash', '#{@timestamp}', '#{@timestamp}');
    INSERT INTO projects VALUES ('#{@project_id}', 'Imported', 'imported', 'cutover fixture', 1, 'SYM', 'https://github.com/example/symphony.git', 'main', 1, 'clone', 1, 1, NULL, NULL, NULL, NULL, '#{@timestamp}', '#{@timestamp}');
    INSERT INTO tracker_configs VALUES ('11000000-0000-0000-0000-000000000001', '#{@project_id}', 'linear', 'https://api.linear.app/graphql', 'SYM', NULL, '{"values":["Todo"]}', '{"values":["Done"]}', 1, '#{@timestamp}', '#{@timestamp}');
    INSERT INTO workflow_versions VALUES ('#{@workflow_id}', '#{@project_id}', 1, '--- workflow fixture ---', '{"tracker":{"kind":"linear","project_slug":"SYM"},"project":{"repository_url":"https://github.com/example/symphony.git"}}', 'Smoke prompt', 'import', 1, '#{@timestamp}', '#{@timestamp}');
    INSERT INTO issues VALUES ('#{@issue_id}', '#{@project_id}', 'linear-1', 'SYM-2', 'Cut over', 'In Progress', 'https://linear.app/example/SYM-2', '{"values":["migration"]}', '{"priority":1}', '#{@timestamp}', '#{@timestamp}');
    INSERT INTO runs VALUES ('#{@run_id}', '#{@project_id}', '#{@workflow_id}', '#{@issue_id}', 'SYM-2', '/data/workspaces/SYM-2', 'succeeded', 1, NULL, '#{@timestamp}', '#{@timestamp}', '#{@timestamp}', '#{@timestamp}', 'centralized', 'issue', NULL, NULL);
    INSERT INTO agent_turns VALUES ('12000000-0000-0000-0000-000000000001', '#{@run_id}', 1, 'succeeded', 'Imported turn', '#{@timestamp}', '#{@timestamp}', '#{@timestamp}', '#{@timestamp}');
    INSERT INTO workspaces VALUES ('13000000-0000-0000-0000-000000000001', '#{@project_id}', 'SYM-2', '/data/workspaces/SYM-2', NULL, 'active', '#{@timestamp}', NULL, '#{@timestamp}', '#{@timestamp}');
    INSERT INTO events VALUES ('14000000-0000-0000-0000-000000000001', '#{@project_id}', '#{@run_id}', 'SYM-2', 'run.completed', '{"result":"ok"}', '#{@timestamp}', '#{@timestamp}', '#{@timestamp}');
    INSERT INTO app_settings VALUES ('default_project_id', '{"id":"#{@project_id}"}', '#{@timestamp}', '#{@timestamp}');
    INSERT INTO workers VALUES ('#{@worker_id}', 'smoke-worker', 'online', '{"values":["linux"]}', '{"sandbox":["workspace-write"]}', 'worker:smoke', '#{@timestamp}', '#{@timestamp}', '#{@timestamp}');
    INSERT INTO worker_sessions VALUES ('#{@session_id}', '#{@worker_id}', 'worker-api-v1', '1.0', 'smoke-instance', 1, '#{@timestamp}', '#{@timestamp}', NULL, 'online', '#{@timestamp}', '#{@timestamp}');
    INSERT INTO tasks VALUES ('#{@task_id}', '#{@project_id}', '#{@run_id}', '#{@workflow_id}', 'SYM-2', 'running', 1, 'worker', '{"labels":["linux"]}', '{"command":"smoke"}', '#{@timestamp}', '#{@timestamp}', NULL, '#{@timestamp}', '#{@timestamp}');
    INSERT INTO task_leases VALUES ('#{@lease_id}', '#{@task_id}', '#{@worker_id}', '#{@session_id}', 'active', 1, '2026-08-28T10:00:00.000000Z', '#{@timestamp}', NULL, '#{@timestamp}', '#{@timestamp}');
    """
  end
end

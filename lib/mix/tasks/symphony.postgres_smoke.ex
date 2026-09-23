defmodule Mix.Tasks.Symphony.PostgresSmoke do
  @moduledoc """
  Runs the opt-in PostgreSQL migration, SQLite cutover, persistence, and
  concurrent-write smoke test against an isolated empty database.
  """

  use Mix.Task

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Config.LegacyWorkflowConvergence
  alias SymphonyElixir.{Persistence, Repo, SQLiteImporter}
  alias SymphonyElixir.Persistence.{EventRecord, Project, WorkflowStore}
  alias SymphonyElixir.Workflow

  @shortdoc "Runs the explicit PostgreSQL integration smoke test"
  @requirements ["app.config"]

  @project_id "10000000-0000-0000-0000-000000000001"
  @workflow_id "20000000-0000-0000-0000-000000000001"
  @issue_id "30000000-0000-0000-0000-000000000001"
  @run_id "40000000-0000-0000-0000-000000000001"
  @worker_id "50000000-0000-0000-0000-000000000001"
  @session_id "60000000-0000-0000-0000-000000000001"
  @legacy_session_id "60000000-0000-0000-0000-000000000002"
  @timestamp "2026-08-27T10:00:00.000000Z"
  @capacity_migration 20_260_905_000_000
  @pre_convergence_migration 20_260_907_000_000
  @convergence_migration 20_260_914_000_000
  @codex_selector_migration 20_260_923_000_000
  @legacy_project_ids [
    "70000000-0000-0000-0000-000000000001",
    "70000000-0000-0000-0000-000000000002"
  ]
  @legacy_workflow_ids [
    "80000000-0000-0000-0000-000000000001",
    "80000000-0000-0000-0000-000000000002"
  ]
  @legacy_hooks %{
    after_create_hook: "echo after-create",
    before_run_hook: "echo before-run",
    after_run_hook: "echo after-run",
    before_remove_hook: "echo before-remove"
  }
  @existing_instance %{
    "config" => %{"polling" => %{"interval_ms" => 12_345}},
    "prompt_body" => "Preserved instance prompt"
  }

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
    migrations_path = :symphony_elixir |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")

    expected_snapshot =
      with_repo!(fn repo ->
        Enum.each([:zero, :single, :equal, :conflict], fn scenario ->
          rebuild_pre_convergence_schema!(repo, migrations_path, scenario)
          rows = seed_legacy_fixture!(repo, scenario)
          migrate_and_verify_convergence!(repo, migrations_path, scenario, rows)
        end)

        rebuild_pre_convergence_schema!(repo, migrations_path, :existing)
        rows = seed_legacy_fixture!(repo, :existing)
        migrate_and_verify_convergence!(repo, migrations_path, :existing, rows)

        rebuild_pre_codex_selector_schema!(repo, migrations_path)
        expected = seed_codex_selector_fixture!(repo)
        migrate_and_verify_codex_selectors!(repo, migrations_path, expected)
        convergence_snapshot!(repo)
      end)

    migrate_release!()

    with_repo!(fn repo ->
      ^expected_snapshot = convergence_snapshot!(repo)
      Mix.shell().info("smoke release_migrator_noop=PASS")
      cleanup_legacy_fixture!(repo)
      verify_postgres_schema!(repo)
      verify_worker_session_compatibility!(repo)
      verify_bootstrap_concurrency!()
    end)
  end

  defp rebuild_pre_convergence_schema!(repo, migrations_path, scenario) do
    SQL.query!(repo, "DROP SCHEMA public CASCADE", [])
    SQL.query!(repo, "CREATE SCHEMA public", [])

    if scenario == :existing do
      Ecto.Migrator.run(repo, migrations_path, :up, to: @capacity_migration)
      seed_pre_repair_worker_session!(repo)
    end

    Ecto.Migrator.run(repo, migrations_path, :up, to: @pre_convergence_migration)
  end

  defp rebuild_pre_codex_selector_schema!(repo, migrations_path) do
    SQL.query!(repo, "DROP SCHEMA public CASCADE", [])
    SQL.query!(repo, "CREATE SCHEMA public", [])
    Ecto.Migrator.run(repo, migrations_path, :up, to: @capacity_migration)
    seed_pre_repair_worker_session!(repo)
    Ecto.Migrator.run(repo, migrations_path, :up, to: @convergence_migration)
  end

  defp seed_codex_selector_fixture!(repo) do
    {:ok, loaded} = Workflow.load()

    missing =
      put_in(
        loaded.config,
        ["codex", "command"],
        "codex -c model=gpt-5.5 -c model_reasoning_effort=xhigh app-server"
      )
      |> update_in(["codex"], &Map.drop(&1, ["model", "reasoning_effort"]))

    explicit =
      loaded.config
      |> put_in(
        ["codex", "command"],
        "codex --model gpt-5.5 --config model_reasoning_effort=xhigh app-server"
      )
      |> put_in(["codex", "model"], "gpt-5.6-sol")
      |> put_in(["codex", "reasoning_effort"], "high")

    expected = [
      codex_selector_row(0, "codex-missing", missing, "Missing selectors", "gpt-5.5", "xhigh"),
      codex_selector_row(1, "codex-explicit", explicit, "Explicit selectors", "gpt-5.6-sol", "high")
    ]

    Enum.each(expected, &insert_current_workflow!(repo, &1))

    insert_setting!(repo, "instance_workflow", %{
      "config" => missing,
      "prompt_body" => "Instance prompt"
    })

    expected
  end

  defp codex_selector_row(index, slug, config, prompt, model, effort) do
    %{
      workflow_id: Enum.fetch!(@legacy_workflow_ids, index),
      project_id: Enum.fetch!(@legacy_project_ids, index),
      project_slug: slug,
      yaml_config: config,
      prompt_body: prompt,
      expected_model: model,
      expected_effort: effort
    }
  end

  defp insert_current_workflow!(repo, row) do
    SQL.query!(
      repo,
      """
      INSERT INTO projects (id, name, slug, enabled, inserted_at, updated_at)
      VALUES ($1::text::uuid, $2, $3, TRUE, NOW(), NOW())
      """,
      [row.project_id, "Codex #{row.project_slug}", row.project_slug]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO workflows (
        id, project_id, raw_workflow_md, yaml_config, prompt_body, source, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3, $4::jsonb, $5, 'migration-smoke', NOW(), NOW()
      )
      """,
      [
        row.workflow_id,
        row.project_id,
        Workflow.to_markdown(row.yaml_config, row.prompt_body),
        row.yaml_config,
        row.prompt_body
      ]
    )
  end

  defp migrate_and_verify_codex_selectors!(repo, migrations_path, expected) do
    [@codex_selector_migration] =
      Ecto.Migrator.run(repo, migrations_path, :up, to: @codex_selector_migration)

    Enum.each(expected, fn row ->
      %{rows: [[yaml_config, raw_workflow_md]]} =
        SQL.query!(
          repo,
          "SELECT yaml_config, raw_workflow_md FROM workflows WHERE id = $1::text::uuid",
          [row.workflow_id]
        )

      "codex app-server" = get_in(yaml_config, ["codex", "command"])
      expected_model = row.expected_model
      expected_effort = row.expected_effort
      ^expected_model = get_in(yaml_config, ["codex", "model"])
      ^expected_effort = get_in(yaml_config, ["codex", "reasoning_effort"])
      {:ok, %{config: ^yaml_config, prompt: prompt}} = Workflow.parse_content(raw_workflow_md)
      ^prompt = row.prompt_body
    end)

    %{"config" => instance_config} = fetch_setting(repo, "instance_workflow")
    "codex app-server" = get_in(instance_config, ["codex", "command"])
    "gpt-5.5" = get_in(instance_config, ["codex", "model"])
    "xhigh" = get_in(instance_config, ["codex", "reasoning_effort"])
    Mix.shell().info("smoke codex_selector_migration result=PASS")
  end

  defp seed_legacy_fixture!(_repo, :zero), do: []

  defp seed_legacy_fixture!(repo, scenario) do
    {:ok, loaded} = Workflow.load()

    rows =
      case scenario do
        :single ->
          [legacy_row(0, "legacy-single", loaded.config, loaded.prompt)]

        :equal ->
          [
            legacy_row(0, "legacy-equal-a", loaded.config, loaded.prompt),
            legacy_row(1, "legacy-equal-b", loaded.config, loaded.prompt)
          ]

        :conflict ->
          different_config = put_in(loaded.config, ["polling", "interval_ms"], 9_999)

          [
            legacy_row(0, "legacy-conflict-a", loaded.config, loaded.prompt),
            legacy_row(1, "Legacy-Conflict-B", different_config, "Different base prompt")
          ]

        :existing ->
          insert_setting!(repo, "instance_workflow", @existing_instance)
          [legacy_row(0, "legacy-existing", loaded.config, loaded.prompt)]
      end

    Enum.each(rows, &insert_legacy_row!(repo, &1))
    rows
  end

  defp legacy_row(index, slug, config, prompt_body) do
    %{
      workflow_id: Enum.fetch!(@legacy_workflow_ids, index),
      project_id: Enum.fetch!(@legacy_project_ids, index),
      project_slug: slug,
      yaml_config: config,
      prompt_body: prompt_body,
      after_create_hook: @legacy_hooks.after_create_hook,
      before_run_hook: @legacy_hooks.before_run_hook,
      after_run_hook: @legacy_hooks.after_run_hook,
      before_remove_hook: @legacy_hooks.before_remove_hook
    }
  end

  defp insert_legacy_row!(repo, row) do
    SQL.query!(
      repo,
      """
      INSERT INTO projects (
        id, name, slug, enabled, after_create_hook, before_run_hook, after_run_hook,
        before_remove_hook, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2, $3, TRUE, $4, $5, $6, $7, NOW(), NOW()
      )
      """,
      [
        row.project_id,
        "Legacy #{row.project_slug}",
        row.project_slug,
        row.after_create_hook,
        row.before_run_hook,
        row.after_run_hook,
        row.before_remove_hook
      ]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO workflows (
        id, project_id, raw_workflow_md, yaml_config, prompt_body, source, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, $3, $4::jsonb, $5, 'migration-smoke', NOW(), NOW()
      )
      """,
      [
        row.workflow_id,
        row.project_id,
        Workflow.to_markdown(row.yaml_config, row.prompt_body),
        row.yaml_config,
        row.prompt_body
      ]
    )
  end

  defp insert_setting!(repo, key, value) do
    SQL.query!(
      repo,
      "INSERT INTO app_settings (key, value, inserted_at, updated_at) VALUES ($1, $2::jsonb, NOW(), NOW())",
      [key, value]
    )
  end

  defp migrate_and_verify_convergence!(repo, migrations_path, scenario, rows) do
    [@convergence_migration] =
      Ecto.Migrator.run(repo, migrations_path, :up, to: @convergence_migration)

    verify_convergence_version!(repo)
    verify_hook_columns_removed!(repo)

    instance_exists? = scenario == :existing
    {:ok, plan} = LegacyWorkflowConvergence.plan(rows, instance_exists?)
    verify_rewritten_workflows!(repo, plan.candidates)
    verify_convergence_settings!(repo, scenario, plan.setting)
    Mix.shell().info("smoke convergence_scenario=#{scenario} result=PASS")
  end

  defp verify_convergence_version!(repo) do
    %{rows: [[1]]} =
      SQL.query!(repo, "SELECT COUNT(*) FROM schema_migrations WHERE version = $1", [@convergence_migration])
  end

  defp verify_hook_columns_removed!(repo) do
    %{rows: [[0]]} =
      SQL.query!(
        repo,
        """
        SELECT COUNT(*)
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name IN (
            'after_create_hook',
            'before_run_hook',
            'after_run_hook',
            'before_remove_hook'
          )
        """,
        []
      )
  end

  defp verify_rewritten_workflows!(repo, candidates) do
    Enum.each(candidates, fn candidate ->
      %{rows: [[yaml_config, "", raw_workflow_md]]} =
        SQL.query!(
          repo,
          """
          SELECT yaml_config, prompt_body, raw_workflow_md
          FROM workflows
          WHERE id = $1::text::uuid
          """,
          [candidate.workflow_id]
        )

      ^yaml_config = candidate.project_config
      ^raw_workflow_md = candidate.raw_workflow_md
      ["project", "tracker"] = yaml_config |> Map.keys() |> Enum.sort()
    end)
  end

  defp verify_convergence_settings!(repo, :zero, :none) do
    nil = fetch_setting(repo, "instance_workflow")
    nil = fetch_setting(repo, "legacy_instance_workflow_candidates")
  end

  defp verify_convergence_settings!(repo, :existing, :none) do
    expected = @existing_instance
    ^expected = fetch_setting(repo, "instance_workflow")
    nil = fetch_setting(repo, "legacy_instance_workflow_candidates")
  end

  defp verify_convergence_settings!(repo, _scenario, {:instance, expected}) do
    ^expected = fetch_setting(repo, "instance_workflow")
    nil = fetch_setting(repo, "legacy_instance_workflow_candidates")
  end

  defp verify_convergence_settings!(repo, :conflict, {:conflict, expected}) do
    nil = fetch_setting(repo, "instance_workflow")
    ^expected = fetch_setting(repo, "legacy_instance_workflow_candidates")
  end

  defp fetch_setting(repo, key) do
    case SQL.query!(repo, "SELECT value FROM app_settings WHERE key = $1", [key]).rows do
      [] -> nil
      [[value]] -> value
    end
  end

  defp convergence_snapshot!(repo) do
    verify_convergence_version!(repo)

    SQL.query!(
      repo,
      """
      SELECT key, value, inserted_at, updated_at
      FROM app_settings
      WHERE key IN ('instance_workflow', 'legacy_instance_workflow_candidates')
      ORDER BY key
      """,
      []
    ).rows
  end

  defp migrate_release! do
    case SymphonyElixir.Release.migrate() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(SymphonyElixir.DatabaseSetup.format_error(reason))
    end
  end

  defp cleanup_legacy_fixture!(repo) do
    SQL.query!(repo, "DELETE FROM projects", [])

    SQL.query!(
      repo,
      "DELETE FROM app_settings WHERE key IN ('instance_workflow', 'legacy_instance_workflow_candidates')",
      []
    )
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

    if foreign_keys < 7, do: Mix.raise("Expected PostgreSQL foreign keys, found #{foreign_keys}")

    %{rows: [[indexes]]} =
      SQL.query!(repo, "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname <> 'schema_migrations_pkey'", [])

    if indexes < 14, do: Mix.raise("Expected PostgreSQL indexes, found #{indexes}")

    verify_hook_columns_removed!(repo)
  end

  defp seed_pre_repair_worker_session!(repo) do
    SQL.query!(
      repo,
      """
      INSERT INTO workers (id, name, status, labels, capabilities, inserted_at, updated_at)
      VALUES ($1::text::uuid, 'migration-smoke-worker', 'online', '{}', '{}', NOW(), NOW())
      """,
      [@worker_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO worker_sessions (
        id, worker_id, protocol_version, total_slots, connected_at, status, inserted_at, updated_at
      )
      VALUES ($1::text::uuid, $2::text::uuid, 'worker-api-v1', 7, NOW(), 'online', NOW(), NOW())
      """,
      [@session_id, @worker_id]
    )
  end

  defp verify_worker_session_compatibility!(repo) do
    %{rows: [["YES", "1"]]} =
      SQL.query!(
        repo,
        """
        SELECT is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'worker_sessions'
          AND column_name = 'total_slots'
        """,
        []
      )

    %{rows: [[7]]} =
      SQL.query!(repo, "SELECT total_slots FROM worker_sessions WHERE id = $1::text::uuid", [@session_id])

    SQL.query!(
      repo,
      """
      INSERT INTO worker_sessions (
        id, worker_id, protocol_version, connected_at, status, inserted_at, updated_at
      )
      VALUES ($1::text::uuid, $2::text::uuid, 'legacy-worker-api-v1', NOW(), 'online', NOW(), NOW())
      """,
      [@legacy_session_id, @worker_id]
    )

    %{rows: [[1]]} =
      SQL.query!(repo, "SELECT total_slots FROM worker_sessions WHERE id = $1::text::uuid", [@legacy_session_id])

    SQL.query!(repo, "DELETE FROM workers WHERE id = $1::text::uuid", [@worker_id])
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

    %{rows: [[@session_id, @worker_id]]} =
      SQL.query!(
        repo,
        "SELECT id::text, worker_id::text FROM worker_sessions WHERE id = $1::text::uuid",
        [@session_id]
      )

    %{rows: [[yaml_config, "", raw_workflow_md]]} =
      SQL.query!(
        repo,
        "SELECT yaml_config, prompt_body, raw_workflow_md FROM workflows WHERE id = $1::text::uuid",
        [@workflow_id]
      )

    ["project", "tracker"] = Enum.sort(Map.keys(yaml_config))
    false = String.contains?(raw_workflow_md, "Smoke prompt")

    %{rows: [[%{"config" => %{}, "prompt_body" => "Smoke prompt"}]]} =
      SQL.query!(repo, "SELECT value FROM app_settings WHERE key = 'instance_workflow'", [])
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
    """
  end
end

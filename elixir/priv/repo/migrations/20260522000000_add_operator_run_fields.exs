defmodule SymphonyElixir.Repo.Migrations.AddOperatorRunFields do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("PRAGMA foreign_keys = OFF")

    cond do
      table_exists?("runs") ->
        rebuild_runs_table()

      table_exists?("runs_new") ->
        execute("ALTER TABLE runs_new RENAME TO runs")
        create_runs_indexes()

      true ->
        raise "runs table is missing"
    end

    execute("PRAGMA foreign_keys = ON")
  end

  defp rebuild_runs_table do
    execute("DROP TABLE IF EXISTS runs_old")
    execute("PRAGMA legacy_alter_table = ON")
    execute("ALTER TABLE runs RENAME TO runs_old")

    execute("""
    CREATE TABLE runs (
      id TEXT PRIMARY KEY,
      project_id TEXT CONSTRAINT runs_project_id_fkey REFERENCES projects(id) ON DELETE SET NULL,
      workflow_version_id TEXT CONSTRAINT runs_workflow_version_id_fkey REFERENCES workflow_versions(id) ON DELETE SET NULL,
      issue_id TEXT CONSTRAINT runs_issue_id_fkey REFERENCES issues(id) ON DELETE SET NULL,
      issue_identifier TEXT,
      workspace_path TEXT,
      status TEXT NOT NULL,
      execution_mode TEXT DEFAULT 'centralized' NOT NULL,
      attempt INTEGER DEFAULT 0 NOT NULL,
      failure_reason TEXT,
      kind TEXT DEFAULT 'issue' NOT NULL,
      profile TEXT,
      label TEXT,
      started_at TEXT,
      finished_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    columns = column_names("runs_old")

    execute("""
    INSERT INTO runs (
      id,
      project_id,
      workflow_version_id,
      issue_id,
      issue_identifier,
      workspace_path,
      status,
      execution_mode,
      attempt,
      failure_reason,
      kind,
      profile,
      label,
      started_at,
      finished_at,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      project_id,
      workflow_version_id,
      issue_id,
      issue_identifier,
      workspace_path,
      status,
      #{select_column(columns, "execution_mode", "'centralized'")},
      attempt,
      failure_reason,
      #{select_column(columns, "kind", "'issue'")},
      #{select_column(columns, "profile", "NULL")},
      #{select_column(columns, "label", "NULL")},
      started_at,
      finished_at,
      inserted_at,
      updated_at
    FROM runs_old
    """)

    execute("DROP TABLE runs_old")
    execute("PRAGMA legacy_alter_table = OFF")

    create_runs_indexes()
  end

  def down do
    execute("PRAGMA foreign_keys = OFF")
    execute("DROP TABLE IF EXISTS runs_old")
    execute("PRAGMA legacy_alter_table = ON")
    execute("ALTER TABLE runs RENAME TO runs_old")

    execute("""
    CREATE TABLE runs (
      id TEXT PRIMARY KEY,
      project_id TEXT CONSTRAINT runs_project_id_fkey REFERENCES projects(id) ON DELETE SET NULL,
      workflow_version_id TEXT CONSTRAINT runs_workflow_version_id_fkey REFERENCES workflow_versions(id) ON DELETE SET NULL,
      issue_id TEXT CONSTRAINT runs_issue_id_fkey REFERENCES issues(id) ON DELETE SET NULL,
      issue_identifier TEXT NOT NULL,
      workspace_path TEXT,
      status TEXT NOT NULL,
      execution_mode TEXT DEFAULT 'centralized' NOT NULL,
      attempt INTEGER DEFAULT 0 NOT NULL,
      failure_reason TEXT,
      started_at TEXT,
      finished_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO runs (
      id,
      project_id,
      workflow_version_id,
      issue_id,
      issue_identifier,
      workspace_path,
      status,
      execution_mode,
      attempt,
      failure_reason,
      started_at,
      finished_at,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      project_id,
      workflow_version_id,
      issue_id,
      COALESCE(issue_identifier, label, kind || ':' || id),
      workspace_path,
      status,
      execution_mode,
      attempt,
      failure_reason,
      started_at,
      finished_at,
      inserted_at,
      updated_at
    FROM runs_old
    """)

    execute("DROP TABLE runs_old")
    execute("PRAGMA legacy_alter_table = OFF")

    create_base_runs_indexes()
    execute("PRAGMA foreign_keys = ON")
  end

  defp create_runs_indexes do
    create_base_runs_indexes()
    execute("CREATE INDEX IF NOT EXISTS runs_kind_index ON runs (kind)")
    execute("CREATE INDEX IF NOT EXISTS runs_inserted_at_id_index ON runs (inserted_at, id)")
  end

  defp create_base_runs_indexes do
    execute("CREATE INDEX IF NOT EXISTS runs_project_id_status_index ON runs (project_id, status)")
    execute("CREATE INDEX IF NOT EXISTS runs_issue_identifier_index ON runs (issue_identifier)")
    execute("CREATE INDEX IF NOT EXISTS runs_execution_mode_status_index ON runs (execution_mode, status)")
  end

  defp column_names(table) do
    repo().query!("PRAGMA table_info(#{table})").rows
    |> Enum.map(fn [_cid, name | _rest] -> name end)
    |> MapSet.new()
  end

  defp table_exists?(table) do
    %{rows: rows} =
      repo().query!("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table])

    rows != []
  end

  defp select_column(columns, name, fallback) do
    if MapSet.member?(columns, name), do: name, else: fallback
  end
end

defmodule SymphonyElixir.Repo.Migrations.EnforceOneRunningIssueRun do
  use Ecto.Migration

  def up do
    execute("""
    WITH ranked AS (
      SELECT id,
             row_number() OVER (
               PARTITION BY issue_id
               ORDER BY started_at ASC NULLS FIRST, inserted_at ASC, id ASC
             ) AS ordinal
      FROM runs
      WHERE kind = 'issue'
        AND status = 'running'
        AND issue_id IS NOT NULL
    )
    UPDATE runs
    SET status = 'failed',
        finished_at = COALESCE(finished_at, NOW()),
        failure_reason = 'runtime_failure',
        failure_evidence = jsonb_build_object(
          'reason', 'duplicate_running_run_migration',
          'migration', 'enforce_one_running_issue_run'
        )
    FROM ranked
    WHERE runs.id = ranked.id
      AND ranked.ordinal > 1
    """)

    create(
      unique_index(:runs, [:issue_id],
        name: :runs_one_running_issue,
        where: "kind = 'issue' AND status = 'running' AND issue_id IS NOT NULL"
      )
    )
  end
end

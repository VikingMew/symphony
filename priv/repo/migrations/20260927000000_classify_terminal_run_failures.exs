defmodule SymphonyElixir.Repo.Migrations.ClassifyTerminalRunFailures do
  use Ecto.Migration

  # Review baseline observed before this backfill was approved: 1,732 NULL
  # reasons, 997 `runtime restarted…`, 185 `class=agent_domain_failure…`, and
  # 2 `stalled for…` rows. The migration is value-based and does not depend on
  # those counts, but operators can use them as a preflight scale reference.

  @failure_reasons ~w(
    environment_unavailable
    source_preparation_timeout
    external_dependency_timeout
    budget_exhausted
    contract_violation
    worker_process_termination
    validation_failed
    runtime_failure
    codex_upstream_capacity
    codex_turn_failed
    cancelled
    operator_stopped
    unknown
  )

  def up do
    alter table(:runs) do
      add(:failure_evidence, :map)
    end

    execute("UPDATE runs SET status = 'completed' WHERE status IN ('success', 'succeeded')")

    execute("""
    UPDATE runs
    SET failure_reason = NULL,
        failure_evidence = NULL
    WHERE status IN ('running', 'completed')
    """)

    execute("""
    UPDATE runs
    SET failure_evidence = CASE
          WHEN failure_reason IN (#{quoted_reasons()})
            THEN jsonb_build_object('migration', 'historical_classification')
          WHEN failure_reason ~* '(erofs|read-only file system|workspace[^[:alnum:]]*(unavailable|unreadable|unwritable))'
            THEN jsonb_build_object(
              'migration', 'historical_mapping',
              'kind', 'environment_unavailable',
              'legacy_failure_reason', failure_reason
            )
          WHEN failure_reason ~* '(clone|fetch|checkout)' AND failure_reason ~* '(timeout|timed[_ -]?out)'
            THEN jsonb_build_object(
              'migration', 'historical_mapping',
              'phase', lower(substring(failure_reason from '(clone|fetch|checkout)')),
              'legacy_failure_reason', failure_reason
            )
          WHEN failure_reason ~* 'linear' AND failure_reason ~* '(transport|timeout|timed[_ -]?out)'
            THEN jsonb_build_object(
              'migration', 'historical_mapping',
              'dependency', 'linear',
              'legacy_failure_reason', failure_reason
            )
          WHEN failure_reason IS NULL
            THEN jsonb_build_object('migration', 'missing_failure_reason')
          ELSE jsonb_build_object(
            'migration', 'unclassified_legacy_reason',
            'legacy_failure_reason', failure_reason
          )
        END,
        failure_reason = CASE
          WHEN failure_reason IN (#{quoted_reasons()}) THEN failure_reason
          WHEN failure_reason ~* '(erofs|read-only file system|workspace[^[:alnum:]]*(unavailable|unreadable|unwritable))'
            THEN 'environment_unavailable'
          WHEN failure_reason ~* '(clone|fetch|checkout)' AND failure_reason ~* '(timeout|timed[_ -]?out)'
            THEN 'source_preparation_timeout'
          WHEN failure_reason ~* 'linear' AND failure_reason ~* '(transport|timeout|timed[_ -]?out)'
            THEN 'external_dependency_timeout'
          ELSE 'unknown'
        END
    WHERE status IN ('failed', 'blocked', 'cancelled', 'stopped')
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM runs
        WHERE status NOT IN ('running', 'completed', 'failed', 'blocked', 'cancelled', 'stopped')
      ) THEN
        RAISE EXCEPTION 'runs contains status outside the closed lifecycle vocabulary';
      END IF;
    END
    $$
    """)

    execute("""
    ALTER TABLE runs
      ADD CONSTRAINT runs_status_closed
      CHECK (status IN ('running', 'completed', 'failed', 'blocked', 'cancelled', 'stopped')),
      ADD CONSTRAINT runs_failure_reason_closed
      CHECK (failure_reason IS NULL OR failure_reason IN (#{quoted_reasons()})),
      ADD CONSTRAINT runs_terminal_failure_matrix
      CHECK (
        (status IN ('running', 'completed') AND failure_reason IS NULL AND failure_evidence IS NULL)
        OR
        (status IN ('failed', 'blocked', 'cancelled', 'stopped')
          AND failure_reason IS NOT NULL
          AND failure_evidence IS NOT NULL
          AND jsonb_typeof(failure_evidence) = 'object'
          AND failure_evidence <> '{}'::jsonb)
      )
    """)
  end

  defp quoted_reasons, do: Enum.map_join(@failure_reasons, ", ", &"'#{&1}'")
end

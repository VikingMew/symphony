defmodule SymphonyElixir.Repo.Migrations.MarkRecordedRunExecutionEvidence do
  use Ecto.Migration

  def up do
    alter table(:runs) do
      add(:execution_evidence_recorded, :boolean, null: false, default: false)
    end

    execute("""
    UPDATE runs
    SET execution_evidence_recorded = TRUE
    WHERE EXISTS (
      SELECT 1
      FROM events
      WHERE events.run_id = runs.id
        AND events.event_type = 'task.accepted'
        AND events.payload -> 'execution' ->> 'execution_requirement' = runs.execution_requirement
        AND events.payload -> 'execution' ->> 'execution_surface' = runs.execution_surface
    )
    """)
  end

  def down do
    alter table(:runs) do
      remove(:execution_evidence_recorded)
    end
  end
end

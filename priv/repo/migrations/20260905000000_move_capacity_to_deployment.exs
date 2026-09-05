defmodule SymphonyElixir.Repo.Migrations.MoveCapacityToDeployment do
  use Ecto.Migration

  def up do
    alter table(:worker_sessions) do
      add(:total_slots, :integer)
    end

    execute("UPDATE worker_sessions SET total_slots = 1 WHERE total_slots IS NULL")

    alter table(:worker_sessions) do
      modify(:total_slots, :integer, null: false)
    end

    execute("""
    UPDATE workflows
    SET yaml_config = jsonb_set(
          COALESCE(yaml_config, '{}'::jsonb),
          '{agent}',
          COALESCE(yaml_config #> '{agent}', '{}'::jsonb)
            - 'max_concurrent_agents'
            - 'max_concurrent_agents_by_state'
        ),
        raw_workflow_md = regexp_replace(
          regexp_replace(raw_workflow_md, E'(?m)^\\s{2}max_concurrent_agents:\\s*.*\\n?', '', 'g'),
          E'(?ms)^\\s{2}max_concurrent_agents_by_state:\\s*\\n(?:\\s{4}.*\\n?)*',
          '',
          'g'
        )
    """)
  end

  def down do
    alter table(:worker_sessions) do
      remove(:total_slots)
    end
  end
end

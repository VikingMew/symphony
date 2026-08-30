defmodule SymphonyElixir.Repo.Migrations.AddReadyToMergeConflictBlocking do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE workflows
    SET yaml_config = jsonb_set(
      yaml_config,
      '{workflow,allowed_transitions}',
      COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb) ||
        '[{"actor":"symphony","from":"Ready to Merge","to":"Blocked"}]'::jsonb
    )
    WHERE NOT COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb) @>
      '[{"actor":"symphony","from":"Ready to Merge","to":"Blocked"}]'::jsonb
    """)
  end

  def down do
    execute("""
    UPDATE workflows
    SET yaml_config = jsonb_set(
      yaml_config,
      '{workflow,allowed_transitions}',
      COALESCE((
        SELECT jsonb_agg(transition)
        FROM jsonb_array_elements(
          COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb)
        ) AS transition
        WHERE transition <> '{"actor":"symphony","from":"Ready to Merge","to":"Blocked"}'::jsonb
      ), '[]'::jsonb)
    )
    """)
  end
end

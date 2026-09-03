defmodule SymphonyElixir.Repo.Migrations.AlignRefinementTodoWorkflow do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE workflows
    SET yaml_config = jsonb_set(
      jsonb_set(
        jsonb_set(
          yaml_config,
          '{workflow,states,Todo}',
          '{"profile":"refinement"}'::jsonb
        ),
        '{tracker,active_states}',
        '["Todo", "Ready", "In Progress"]'::jsonb
      ),
      '{workflow,allowed_transitions}',
      COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb) ||
        '[{"actor":"codex","from":"Todo","profile":"refinement","to":"Refining"}]'::jsonb
    )
    WHERE yaml_config IS NOT NULL
    """)
  end

  def down, do: :ok
end

defmodule SymphonyElixir.Repo.Migrations.AddIssueBlockingDecisions do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add(:blocking_decision, :map)
      add(:no_progress_streak, :integer, null: false, default: 0)
    end

    create(
      index(:issues, [:project_id],
        where: "blocking_decision IS NOT NULL",
        name: :issues_blocking_decision_index
      )
    )

    execute(
      """
      UPDATE workflows
      SET yaml_config = jsonb_set(
        jsonb_set(
          yaml_config,
          '{workflow,human_review_states}',
          COALESCE(yaml_config #> '{workflow,human_review_states}', '[]'::jsonb) || '["Blocked"]'::jsonb
        ),
        '{workflow,allowed_transitions}',
        COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb) ||
          '[
            {"actor":"symphony","from":"Refining","to":"Blocked"},
            {"actor":"symphony","from":"Ready","to":"Blocked"},
            {"actor":"symphony","from":"In Progress","to":"Blocked"},
            {"actor":"human","from":"Blocked","to":"Ready"},
            {"actor":"human","from":"Blocked","to":"Needs Refinement Review"},
            {"actor":"human","from":"Blocked","to":"Canceled"}
          ]'::jsonb
      )
      WHERE NOT COALESCE(yaml_config #> '{workflow,human_review_states}', '[]'::jsonb) @> '["Blocked"]'::jsonb
      """,
      "SELECT 1"
    )
  end
end

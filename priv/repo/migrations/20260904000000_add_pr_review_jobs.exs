defmodule SymphonyElixir.Repo.Migrations.AddPrReviewJobs do
  use Ecto.Migration

  def change do
    create table(:review_jobs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false)
      add(:issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false)
      add(:run_id, references(:runs, type: :binary_id, on_delete: :nilify_all))
      add(:tracker_issue_id, :text, null: false)
      add(:issue_identifier, :text, null: false)
      add(:pr_url, :text, null: false)
      add(:repository, :text, null: false)
      add(:base_ref, :text, null: false)
      add(:head_ref, :text, null: false)
      add(:head_oid, :text, null: false)
      add(:status, :text, null: false, default: "intent")
      add(:result, :map)
      add(:delivery, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:review_jobs, [:project_id, :issue_id, :pr_url, :head_oid]))
    create(index(:review_jobs, [:status, :inserted_at]))

    execute(
      """
      UPDATE workflows
      SET yaml_config = jsonb_set(
        yaml_config,
        '{workflow,allowed_transitions}',
        COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb) ||
          '[{"actor":"human","from":"Blocked","to":"In Progress"}]'::jsonb
      )
      WHERE NOT COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb) @>
        '[{"actor":"human","from":"Blocked","to":"In Progress"}]'::jsonb
      """,
      """
      UPDATE workflows
      SET yaml_config = jsonb_set(
        yaml_config,
        '{workflow,allowed_transitions}',
        COALESCE((
          SELECT jsonb_agg(transition)
          FROM jsonb_array_elements(
            COALESCE(yaml_config #> '{workflow,allowed_transitions}', '[]'::jsonb)
          ) transition
          WHERE transition <> '{"actor":"human","from":"Blocked","to":"In Progress"}'::jsonb
        ), '[]'::jsonb)
      )
      """
    )
  end
end

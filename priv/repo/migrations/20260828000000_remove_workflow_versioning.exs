defmodule SymphonyElixir.Repo.Migrations.RemoveWorkflowVersioning do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM workflow_versions WHERE active GROUP BY project_id HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'cannot remove workflow versioning: project has multiple active workflows';
      END IF;
    END
    $$
    """)

    drop_if_exists(index(:tasks, [:workflow_version_id]))
    alter table(:tasks), do: remove(:workflow_version_id)

    drop_if_exists(index(:runs, [:workflow_version_id]))
    alter table(:runs), do: remove(:workflow_version_id)

    execute("DELETE FROM workflow_versions WHERE NOT active")
    rename(table(:workflow_versions), to: table(:workflows))

    alter table(:workflows) do
      remove(:version)
      remove(:active)
    end

    create(unique_index(:workflows, [:project_id]))
  end

  def down do
    raise "workflow version removal is irreversible"
  end
end

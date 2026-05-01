defmodule SymphonyElixir.Repo.Migrations.CreateSymphonyPersistence do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:username, :text, null: false)
      add(:password_hash, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:users, [:username]))

    create table(:projects, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :text, null: false)
      add(:slug, :text, null: false)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: true)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:projects, [:slug]))

    create table(:tracker_configs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false)
      add(:kind, :text, null: false)
      add(:endpoint, :text)
      add(:project_slug, :text, null: false)
      add(:api_key_secret_ref, :text)
      add(:active_states, :map, null: false, default: "[]")
      add(:terminal_states, :map, null: false, default: "[]")
      add(:enabled, :boolean, null: false, default: true)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:tracker_configs, [:project_id]))

    create table(:workflow_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false)
      add(:version, :integer, null: false)
      add(:raw_workflow_md, :text, null: false)
      add(:yaml_config, :map, null: false, default: "{}")
      add(:prompt_body, :text, null: false)
      add(:source, :text, null: false, default: "manual")
      add(:active, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:workflow_versions, [:project_id, :version]))
    create(index(:workflow_versions, [:project_id, :active]))

    create table(:issues, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all))
      add(:tracker_issue_id, :text)
      add(:identifier, :text, null: false)
      add(:title, :text)
      add(:state, :text)
      add(:url, :text)
      add(:labels, :map, null: false, default: "[]")
      add(:snapshot, :map, null: false, default: "{}")
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:issues, [:project_id]))
    create(unique_index(:issues, [:project_id, :identifier]))

    create table(:runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :nilify_all))
      add(:workflow_version_id, references(:workflow_versions, type: :binary_id, on_delete: :nilify_all))
      add(:issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all))
      add(:issue_identifier, :text, null: false)
      add(:workspace_path, :text)
      add(:status, :text, null: false)
      add(:attempt, :integer, null: false, default: 0)
      add(:failure_reason, :text)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:runs, [:project_id, :status]))
    create(index(:runs, [:issue_identifier]))

    create table(:agent_turns, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:turn_index, :integer, null: false)
      add(:status, :text, null: false)
      add(:summary, :text)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_turns, [:run_id, :turn_index]))

    create table(:workspaces, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :nilify_all))
      add(:issue_identifier, :text, null: false)
      add(:path, :text, null: false)
      add(:host, :text)
      add(:status, :text, null: false, default: "active")
      add(:created_at, :utc_datetime_usec)
      add(:cleaned_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:workspaces, [:project_id, :issue_identifier]))

    create table(:events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :nilify_all))
      add(:run_id, references(:runs, type: :binary_id, on_delete: :nilify_all))
      add(:issue_identifier, :text)
      add(:event_type, :text, null: false)
      add(:payload, :map, null: false, default: "{}")
      add(:occurred_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:events, [:project_id, :occurred_at]))
    create(index(:events, [:run_id, :occurred_at]))

    create table(:app_settings, primary_key: false) do
      add(:key, :text, primary_key: true)
      add(:value, :map, null: false, default: "{}")
      timestamps(type: :utc_datetime_usec)
    end
  end
end


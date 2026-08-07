defmodule SymphonyElixir.Repo.Migrations.CreateWorkerControlPlane do
  use Ecto.Migration

  def change do
    create table(:workers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :text, null: false)
      add(:status, :text, null: false, default: "offline")
      add(:labels, :map, null: false, default: "{}")
      add(:capabilities, :map, null: false, default: "{}")
      add(:credential_ref, :text)
      add(:last_seen_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:workers, [:name]))
    create(index(:workers, [:status]))
    create(index(:workers, [:last_seen_at]))

    create table(:worker_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:worker_id, references(:workers, type: :binary_id, on_delete: :delete_all), null: false)
      add(:protocol_version, :text, null: false)
      add(:worker_version, :text)
      add(:instance_id, :text)
      add(:connected_at, :utc_datetime_usec, null: false)
      add(:last_heartbeat_at, :utc_datetime_usec)
      add(:disconnected_at, :utc_datetime_usec)
      add(:status, :text, null: false, default: "online")
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:worker_sessions, [:worker_id]))
    create(index(:worker_sessions, [:status, :last_heartbeat_at]))

    create table(:tasks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :nilify_all))
      add(:run_id, references(:runs, type: :binary_id, on_delete: :nilify_all))
      add(:workflow_version_id, references(:workflow_versions, type: :binary_id, on_delete: :nilify_all))
      add(:issue_identifier, :text)
      add(:status, :text, null: false, default: "queued")
      add(:priority, :integer, null: false, default: 0)
      add(:execution_mode, :text, null: false, default: "worker")
      add(:required_capabilities, :map, null: false, default: "{}")
      add(:payload, :map, null: false, default: "{}")
      add(:queued_at, :utc_datetime_usec, null: false)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:tasks, [:project_id, :status]))
    create(index(:tasks, [:status, :priority, :queued_at]))
    create(index(:tasks, [:run_id]))
    create(index(:tasks, [:issue_identifier]))

    create table(:task_leases, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false)
      add(:worker_id, references(:workers, type: :binary_id, on_delete: :nilify_all))
      add(:worker_session_id, references(:worker_sessions, type: :binary_id, on_delete: :nilify_all))
      add(:status, :text, null: false, default: "active")
      add(:attempt, :integer, null: false, default: 1)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:acquired_at, :utc_datetime_usec, null: false)
      add(:released_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:task_leases, [:worker_id, :status]))
    create(index(:task_leases, [:worker_session_id]))
    create(index(:task_leases, [:expires_at]))
    create(unique_index(:task_leases, [:task_id], where: "status = 'active'"))
  end
end

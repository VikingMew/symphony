defmodule SymphonyElixir.Repo.Migrations.AddHostProbeExecutionEvidence do
  use Ecto.Migration

  def change do
    alter table(:worker_sessions) do
      add(:execution_surface, :text, null: false, default: "container_worker")
      add(:probe_id, :text)
      add(:capabilities, :map, null: false, default: %{"values" => []})
      add(:capability_digest, :text)
      add(:heartbeat_interval_seconds, :integer, null: false, default: 10)
      add(:lease_duration_seconds, :integer, null: false, default: 60)
    end

    alter table(:runs) do
      add(:execution_requirement, :text, null: false, default: "default")
      add(:execution_surface, :text, null: false, default: "panel")
      add(:probe_id, :text)
      add(:worker_session_id, :binary_id)
    end

    execute(
      "UPDATE runs SET execution_surface = 'container_worker' WHERE execution_mode = 'worker'",
      "UPDATE runs SET execution_surface = 'panel' WHERE execution_mode = 'worker'"
    )
  end
end

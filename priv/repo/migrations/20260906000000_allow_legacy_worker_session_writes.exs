defmodule SymphonyElixir.Repo.Migrations.AllowLegacyWorkerSessionWrites do
  use Ecto.Migration

  def up do
    alter table(:worker_sessions) do
      modify(:total_slots, :integer, null: true, default: 1)
    end
  end

  def down do
    alter table(:worker_sessions) do
      modify(:total_slots, :integer, null: false, default: nil)
    end
  end
end

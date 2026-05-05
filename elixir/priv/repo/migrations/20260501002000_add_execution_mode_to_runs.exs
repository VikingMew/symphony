defmodule SymphonyElixir.Repo.Migrations.AddExecutionModeToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add(:execution_mode, :text, null: false, default: "centralized")
    end

    create(index(:runs, [:execution_mode, :status]))
  end
end

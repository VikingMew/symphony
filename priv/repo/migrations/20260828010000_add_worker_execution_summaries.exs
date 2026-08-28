defmodule SymphonyElixir.Repo.Migrations.AddWorkerExecutionSummaries do
  use Ecto.Migration

  def change do
    alter table(:tasks), do: add(:execution_summary, :map)
    alter table(:runs), do: add(:execution_summary, :map)
  end
end

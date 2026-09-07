defmodule SymphonyElixir.Repo.Migrations.RemovePersistedTaskQueue do
  use Ecto.Migration

  def up do
    drop(table(:task_leases))
    drop(table(:tasks))
  end

  def down do
    raise "the pre-release persisted task queue is intentionally not recoverable"
  end
end

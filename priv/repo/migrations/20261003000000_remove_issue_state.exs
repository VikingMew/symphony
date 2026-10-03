defmodule SymphonyElixir.Repo.Migrations.RemoveIssueState do
  use Ecto.Migration

  def up do
    alter table(:issues) do
      remove(:state)
    end
  end

  def down do
    alter table(:issues) do
      add(:state, :text)
    end
  end
end

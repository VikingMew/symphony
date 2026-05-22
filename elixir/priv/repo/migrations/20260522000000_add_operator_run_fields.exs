defmodule SymphonyElixir.Repo.Migrations.AddOperatorRunFields do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add(:kind, :text, null: false, default: "issue")
      add(:profile, :text)
      add(:label, :text)
      modify(:issue_identifier, :text, null: true, from: {:text, null: false})
    end

    create(index(:runs, [:kind]))
    create(index(:runs, [:inserted_at, :id]))
  end
end

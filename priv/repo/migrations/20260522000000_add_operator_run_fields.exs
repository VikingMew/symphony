defmodule SymphonyElixir.Repo.Migrations.AddOperatorRunFields do
  use Ecto.Migration

  def up do
    alter table(:runs) do
      modify(:issue_identifier, :text, null: true, from: {:text, null: false})
      add(:kind, :text, null: false, default: "issue")
      add(:profile, :text)
      add(:label, :text)
    end

    create(index(:runs, [:kind]))
    create(index(:runs, [:inserted_at, :id]))
  end

  def down do
    execute("""
    UPDATE runs
    SET issue_identifier = COALESCE(issue_identifier, label, kind || ':' || id::text)
    WHERE issue_identifier IS NULL
    """)

    drop(index(:runs, [:inserted_at, :id]))
    drop(index(:runs, [:kind]))

    alter table(:runs) do
      remove(:label)
      remove(:profile)
      remove(:kind)
      modify(:issue_identifier, :text, null: false, from: {:text, null: true})
    end
  end
end

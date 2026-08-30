defmodule SymphonyElixir.Repo.Migrations.AddFailureTaxonomy do
  use Ecto.Migration

  def up do
    alter table(:runs) do
      add(:failure_code, :string)
      add(:failure_detail, :text)
    end

    execute("UPDATE runs SET failure_code = 'legacy_unclassified', failure_detail = failure_reason WHERE failure_reason IS NOT NULL AND failure_code IS NULL")
  end

  def down do
    alter table(:runs) do
      remove(:failure_code)
      remove(:failure_detail)
    end
  end
end

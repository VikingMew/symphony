defmodule SymphonyElixir.Repo.Migrations.AddProjectSettingsFields do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add(:linear_project_slug, :text)
      add(:repository_url, :text)
      add(:default_branch, :text, null: false, default: "main")
    end
  end
end

defmodule SymphonyElixir.Repo.Migrations.AddProjectHooksFields do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add(:after_create_hook, :text)
      add(:before_run_hook, :text)
      add(:after_run_hook, :text)
      add(:before_remove_hook, :text)
    end
  end
end

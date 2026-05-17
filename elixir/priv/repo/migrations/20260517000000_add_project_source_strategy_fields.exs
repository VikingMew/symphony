defmodule SymphonyElixir.Repo.Migrations.AddProjectSourceStrategyFields do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add(:checkout_depth, :integer, null: false, default: 1)
      add(:source_strategy, :text, null: false, default: "clone")
      add(:worktree_base_path, :text)
      add(:worktree_root, :text)
      add(:worktree_fetch, :boolean, null: false, default: true)
      add(:worktree_cleanup, :boolean, null: false, default: true)
    end
  end
end

defmodule SymphonyElixir.Repo.Migrations.RemoveProjectWorktreeRoots do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      remove(:worktree_base_path, :text)
      remove(:worktree_root, :text)
    end
  end
end

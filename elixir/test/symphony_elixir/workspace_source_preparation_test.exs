defmodule SymphonyElixir.WorkspaceSourcePreparationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workspace.SourcePreparation

  test "repository and worktree roots default from shared workspace root" do
    settings = %{workspace: %{root: "/tmp/symphony", repository_base_root: nil, worktree_base_root: nil}, project: project()}

    assert SourcePreparation.repository_base_root(settings) == "/tmp/symphony/repositories"
    assert SourcePreparation.worktree_base_root(settings) == "/tmp/symphony/worktrees"
  end

  test "repository cache path is stable and repository-name based" do
    settings = %{
      workspace: %{root: "/tmp/symphony", repository_base_root: "/cache/repos", worktree_base_root: "/cache/worktrees"},
      project: project(repository_url: "git@github.com:org/my repo.git", default_branch: "main")
    }

    path = SourcePreparation.repository_cache_path(settings)

    assert String.starts_with?(path, "/cache/repos/my_repo-")
    assert String.length(Path.basename(path)) > String.length("my_repo-")
  end

  test "worktree branch sanitizes issue identifiers" do
    assert SourcePreparation.worktree_branch("CCR 5/foo") == "symphony/CCR_5_foo"
  end

  defp project(overrides \\ []) do
    Map.merge(
      %{
        repository_url: "git@github.com:org/repo.git",
        default_branch: "main"
      },
      Map.new(overrides)
    )
  end
end

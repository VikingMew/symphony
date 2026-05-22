defmodule SymphonyElixir.Workspace.WorktreeSourcePreparationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workspace.SourcePreparation

  test "worktree source strategy rejects non-empty invalid base repo path" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-invalid-base-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      base_path = Path.join([test_root, "cache", "base"])
      worktree_root = Path.join(test_root, "worktrees")

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "worktree source\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      invalid_base_path = repository_cache_path(base_path, source_repo, "main")
      File.mkdir_p!(invalid_base_path)
      File.write!(Path.join(invalid_base_path, "not-a-git-repo"), "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_repository_url: source_repo,
        project_default_branch: "main",
        project_source_strategy: "worktree",
        workspace_repository_base_root: base_path,
        workspace_worktree_base_root: worktree_root
      )

      assert {:error, {:invalid_worktree_base_repo, ^invalid_base_path}} = Workspace.create_for_issue("WT-BAD")
      refute File.exists?(Path.join([worktree_root, "WT-BAD", ".git"]))
    after
      File.rm_rf(test_root)
    end
  end

  defp repository_cache_path(base_root, repository_url, branch) do
    settings = %{
      project: %{repository_url: repository_url, default_branch: branch},
      workspace: %{repository_base_root: base_root}
    }

    SourcePreparation.repository_cache_path(settings)
  end
end

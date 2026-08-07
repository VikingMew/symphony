defmodule SymphonyElixir.Workspace.SourcePreparationLayoutTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workspace.SourcePreparation

  test "workspace root follows source strategy" do
    settings = %{
      project: %{source_strategy: "clone"},
      workspace: %{root: "/tmp/workspaces", worktree_base_root: "/tmp/worktrees"}
    }

    assert SourcePreparation.workspace_root(settings) == "/tmp/workspaces"

    settings = put_in(settings, [:project, :source_strategy], "worktree")

    assert SourcePreparation.workspace_root(settings) == "/tmp/worktrees"
  end

  test "workspace path is canonicalized locally and root-relative remotely" do
    settings = %{
      project: %{source_strategy: "clone"},
      workspace: %{root: System.tmp_dir!(), worktree_base_root: nil}
    }

    assert {:ok, local_path} = SourcePreparation.workspace_path_for_issue("CCR-1", nil, settings)
    assert {:ok, expected_path} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "CCR-1"))
    assert local_path == expected_path

    assert SourcePreparation.workspace_path_for_issue("CCR-1", "worker-a", settings) ==
             {:ok, Path.join(System.tmp_dir!(), "CCR-1")}
  end
end

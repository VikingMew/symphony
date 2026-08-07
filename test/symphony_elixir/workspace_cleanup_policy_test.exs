defmodule SymphonyElixir.WorkspaceCleanupPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkspaceCleanupPolicy

  test "local delete allows descendants but rejects the configured root" do
    root = Path.join(System.tmp_dir!(), "symphony-cleanup-policy-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "ISSUE-1")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    assert :ok = WorkspaceCleanupPolicy.validate_local_delete(workspace, roots: [root])
    assert {:error, {:cleanup_path_equals_root, _}} = WorkspaceCleanupPolicy.validate_local_delete(root, roots: [root])
  end

  test "local delete rejects symlink escapes" do
    root = Path.join(System.tmp_dir!(), "symphony-cleanup-root-#{System.unique_integer([:positive])}")
    outside = Path.join(System.tmp_dir!(), "symphony-cleanup-outside-#{System.unique_integer([:positive])}")
    link = Path.join(root, "escape")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, link)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    assert {:error, {:cleanup_path_outside_roots, _, _}} =
             WorkspaceCleanupPolicy.validate_local_delete(link, roots: [root])
  end

  test "local delete rejects paths that would remove protected roots" do
    root = Path.join(System.tmp_dir!(), "symphony-cleanup-policy-#{System.unique_integer([:positive])}")
    protected = Path.join([root, "repo", ".git"])

    File.mkdir_p!(protected)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:cleanup_path_contains_protected_path, _, _}} =
             WorkspaceCleanupPolicy.validate_local_delete(Path.join(root, "repo"), roots: [root], protected_paths: [protected])
  end

  test "remote delete validates strings against the remote root" do
    assert :ok = WorkspaceCleanupPolicy.validate_remote_delete("/remote/workspaces/ISSUE-1", "/remote/workspaces")

    assert {:error, {:cleanup_path_equals_root, "/remote/workspaces"}} =
             WorkspaceCleanupPolicy.validate_remote_delete("/remote/workspaces", "/remote/workspaces")

    assert {:error, {:cleanup_path_outside_roots, "/remote/elsewhere", ["/remote/workspaces"]}} =
             WorkspaceCleanupPolicy.validate_remote_delete("/remote/elsewhere", "/remote/workspaces")
  end
end

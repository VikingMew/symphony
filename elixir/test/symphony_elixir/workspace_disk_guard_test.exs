defmodule SymphonyElixir.WorkspaceDiskGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkspaceDiskGuard

  test "allows startup when all workspace roots meet the minimum" do
    settings = settings(min_free_bytes: 100)

    assert {:ok, _summary} =
             WorkspaceDiskGuard.check(settings,
               free_bytes_fun: fn _path -> {:ok, 101} end
             )
  end

  test "blocks startup when a workspace root is below the configured minimum" do
    settings = settings(min_free_bytes: 100)

    assert {:error, reason} =
             WorkspaceDiskGuard.check(settings,
               free_bytes_fun: fn _path -> {:ok, 99} end
             )

    assert reason.reason == :low_disk_space
    assert reason.free_bytes == 99
    assert reason.min_free_bytes == 100
    assert reason.setting == "Settings / Workflow / Runtime / Minimum free bytes"
  end

  test "zero minimum disables the disk-space check" do
    settings = settings(min_free_bytes: 0)

    assert {:ok, %{free_bytes: :unchecked}} =
             WorkspaceDiskGuard.check(settings,
               free_bytes_fun: fn _path -> flunk("disk check should be skipped") end
             )
  end

  defp settings(attrs) do
    root = Path.join(System.tmp_dir!(), "symphony-disk-guard-test")

    %{
      workspace: %{
        root: root,
        repository_base_root: nil,
        worktree_base_root: nil,
        min_free_bytes: Keyword.fetch!(attrs, :min_free_bytes)
      },
      project: %{repository_url: "git@example.test:repo.git", default_branch: "main"}
    }
  end
end

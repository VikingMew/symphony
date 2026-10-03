defmodule SymphonyElixir.WorkspacePreflightTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkspacePreflight

  @tag :tmp_dir
  test "settings save allows existing and missing creatable roots", %{tmp_dir: tmp_dir} do
    missing = Path.join([tmp_dir, "missing", "root"])

    assert :ok = WorkspacePreflight.check(:settings_save, root: tmp_dir)
    assert :ok = WorkspacePreflight.check(:settings_save, root: missing)
    assert File.exists?(missing) == false
  end

  @tag :tmp_dir
  test "settings save rejects a regular file as not creatable", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "workspace-file")
    File.write!(path, "not a directory")

    assert {:error, %{kind: :not_creatable, path: expanded, reason: {:not_directory, :regular}}} =
             WorkspacePreflight.check(:settings_save, root: path)

    assert expanded == Path.expand(path)
  end

  test "path metadata seams preserve not-creatable and unreadable reasons" do
    root = "relative/workspace"
    expanded = Path.expand(root)

    assert {:error, %{kind: :not_creatable, path: ^expanded, reason: :enotdir}} =
             WorkspacePreflight.check(:settings_save,
               root: root,
               path_info_fun: fn ^expanded -> {:error, :enotdir} end
             )

    assert {:error, %{kind: :unreadable, path: ^expanded, reason: :eacces}} =
             WorkspacePreflight.check(:settings_save,
               root: root,
               path_info_fun: fn ^expanded -> {:error, :eacces} end
             )
  end

  @tag :tmp_dir
  test "write probe failures distinguish existing and missing roots", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing")

    assert {:error, %{kind: :not_writable, path: path, reason: :erofs}} =
             WorkspacePreflight.check(:settings_save,
               root: tmp_dir,
               write_probe_fun: fn ^tmp_dir -> {:error, :erofs} end
             )

    assert path == Path.expand(tmp_dir)

    assert {:error, %{kind: :not_creatable, path: missing_path, reason: :eacces}} =
             WorkspacePreflight.check(:settings_save,
               root: missing,
               write_probe_fun: fn ^tmp_dir -> {:error, :eacces} end
             )

    assert missing_path == Path.expand(missing)
  end

  @tag :tmp_dir
  test "pre-listen checks root before disk space even when the threshold is disabled", %{tmp_dir: tmp_dir} do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    settings = settings(tmp_dir, 0)

    assert :ok =
             WorkspacePreflight.check(:pre_listen,
               settings: settings,
               path_info_fun: fn path ->
                 Agent.update(calls, &[{:path, path} | &1])
                 File.stat(path)
               end,
               write_probe_fun: fn path ->
                 Agent.update(calls, &[{:probe, path} | &1])
                 :ok
               end,
               free_bytes_fun: fn path ->
                 Agent.update(calls, &[{:disk, path} | &1])
                 {:ok, 1_000}
               end
             )

    assert calls |> Agent.get(&Enum.reverse/1) == [{:path, tmp_dir}, {:probe, tmp_dir}]
  end

  @tag :tmp_dir
  test "pre-listen preserves disk guard rejection kinds and reasons", %{tmp_dir: tmp_dir} do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    settings = settings(tmp_dir, 100)

    assert {:error, %{kind: :low_disk_space, path: path, reason: low_reason}} =
             WorkspacePreflight.check(:pre_listen,
               settings: settings,
               path_info_fun: fn path ->
                 Agent.update(calls, &[{:path, path} | &1])
                 File.stat(path)
               end,
               write_probe_fun: fn path ->
                 Agent.update(calls, &[{:probe, path} | &1])
                 :ok
               end,
               free_bytes_fun: fn path ->
                 Agent.update(calls, &[{:disk, path} | &1])
                 {:ok, 99}
               end
             )

    assert path == Path.expand(tmp_dir)
    assert low_reason.reason == :low_disk_space
    assert low_reason.free_bytes == 99

    assert calls |> Agent.get(&Enum.reverse/1) == [
             {:path, tmp_dir},
             {:probe, tmp_dir},
             {:disk, tmp_dir},
             {:disk, tmp_dir},
             {:disk, tmp_dir}
           ]

    assert {:error, %{kind: :disk_space_unavailable, path: ^path, reason: unavailable_reason}} =
             WorkspacePreflight.check(:pre_listen,
               settings: settings,
               free_bytes_fun: fn ^tmp_dir -> {:error, :no_stat} end
             )

    assert unavailable_reason.reason == :disk_space_unavailable
    assert unavailable_reason.detail == ":no_stat"
  end

  test "pre-listen returns root rejection without reaching disk space" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    root = Path.expand("unreadable-workspace")

    assert {:error, %{kind: :unreadable, path: ^root, reason: :eacces}} =
             WorkspacePreflight.check(:pre_listen,
               settings: settings(root, 100),
               path_info_fun: fn ^root ->
                 Agent.update(calls, &[:root | &1])
                 {:error, :eacces}
               end,
               free_bytes_fun: fn path ->
                 Agent.update(calls, &[{:disk, path} | &1])
                 {:ok, 1_000}
               end
             )

    assert Agent.get(calls, & &1) == [:root]
  end

  defp settings(root, min_free_bytes) do
    %{
      workspace: %{
        root: root,
        repository_base_root: nil,
        worktree_base_root: nil,
        min_free_bytes: min_free_bytes
      },
      project: %{repository_url: "git@example.test:repo.git", default_branch: "main"}
    }
  end
end

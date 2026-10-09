defmodule SymphonyElixir.AgentCodeNCheck.BaselineLocationsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.AgentCodeNCheck
  alias SymphonyElixir.AgentCodeNCheck.BaselineLocations

  setup do
    root = Path.join(System.tmp_dir!(), "navigation-location-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "AGENTS.md"), "### Build\n`mix build`\n### Run\n`mix symphony.migrate`\n### Test\n`scripts/check.sh`\n[module map](docs/design.md)\n`rg name lib`\n")
    File.write!(Path.join(root, "lib/alpha.ex"), "defmodule Demo.Alpha do\n  def shared, do: :ok\nend\n")
    File.write!(Path.join(root, "lib/beta.ex"), "defmodule Demo.Beta do\n  def shared, do: :ok\nend\n")
    refresh_location_fixture(root)
    location_git!(root, ["init", "-q"])
    location_git!(root, ["add", "."])
    location_git!(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Navigation baseline fixture"])
    location_git!(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    %{root: root}
  end

  test "Git-proven line insertions relocate exact rows without changing the waterline", %{root: root} do
    path = Path.join(root, "lib/alpha.ex")
    File.write!(path, "\n\n" <> File.read!(path))
    refresh_location_fixture(root)
    report = AgentCodeNCheck.check(root: root)
    assert report["status"] == "pass"
    assert report["errors"] == []
    assert report["navigation_baseline_remaining"] == 1
    assert report["findings"] == ["N-01|function|shared|lib/alpha.ex:4,lib/beta.ex:2"]
  end

  test "adding a location to an existing collision still fails even after refreshing rows", %{root: root} do
    path = Path.join(root, "lib/alpha.ex")
    File.write!(path, "\n" <> File.read!(path))
    File.write!(Path.join(root, "lib/gamma.ex"), "defmodule Demo.Gamma do\n  def shared, do: :ok\nend\n")
    refresh_location_fixture(root)
    report = AgentCodeNCheck.check(root: root)
    assert report["status"] == "fail"
    assert report["errors"] == ["baseline.added: N-01|function|shared|lib/alpha.ex:3,lib/beta.ex:2,lib/gamma.ex:2"]
  end

  test "rewritten declaration lines cannot be relabeled as pure moves", %{root: root} do
    path = Path.join(root, "lib/alpha.ex")
    File.write!(path, String.replace(File.read!(path), "def shared,", "def shared(_value),"))
    refresh_location_fixture(root)
    report = AgentCodeNCheck.check(root: root)
    assert report["status"] == "fail"
    assert report["errors"] == ["baseline.added: N-01|function|shared|lib/alpha.ex:2,lib/beta.ex:2"]
  end

  test "deleted declarations must remove their stale baseline row", %{root: root} do
    File.rm!(Path.join(root, "lib/beta.ex"))
    assert AgentCodeNCheck.check(root: root)["status"] == "fail"
    File.rm!(Path.join(root, "config/agent_code_navigation_baseline.yml"))
    assert AgentCodeNCheck.check(root: root)["status"] == "pass"
  end

  test "unavailable Git history remains a hard failure", %{root: root} do
    location_git!(root, ["update-ref", "-d", "refs/remotes/origin/main"])
    report = AgentCodeNCheck.check(root: root)
    assert report["status"] == "fail"
    assert Enum.any?(report["errors"], &String.starts_with?(&1, "baseline.merge_base:"))
  end

  test "line deletions map module and function coordinates back exactly", %{root: root} do
    path = Path.join(root, "lib/alpha.ex")
    File.write!(path, "\n\n" <> File.read!(path))
    location_git!(root, ["add", "."])
    location_git!(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Add preamble"])
    File.write!(path, String.trim_leading(File.read!(path), "\n"))

    assert BaselineLocations.relocate_baseline(root, "HEAD", [
             "N-05|file-module-mismatch|lib/alpha.ex|expected:Other|actual:Demo.Alpha@3",
             "N-01|function|shared|lib/alpha.ex:4,lib/beta.ex:2"
           ]) ==
             {:ok,
              [
                "N-01|function|shared|lib/alpha.ex:2,lib/beta.ex:2",
                "N-05|file-module-mismatch|lib/alpha.ex|expected:Other|actual:Demo.Alpha@1"
              ]}
  end

  test "a Git diff failure cannot authorize baseline rows", %{root: root} do
    assert {:error, message} = BaselineLocations.relocate_baseline(root, "missing-revision", [])
    assert String.starts_with?(message, "baseline.location_diff: git exited 128:")
  end

  defp refresh_location_fixture(root) do
    findings = AgentCodeNCheck.check(root: root, base_baseline: :missing)["findings"]
    File.write!(Path.join(root, "config/agent_code_navigation_baseline.yml"), Jason.encode!(findings))
  end

  defp location_git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end

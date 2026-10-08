defmodule SymphonyElixir.AgentCodeNCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentCodeNCheck

  setup do
    root = Path.join(System.tmp_dir!(), "agent-code-n-check-#{System.unique_integer([:positive, :monotonic])}")

    for path <- ~w(.github config docs lib scripts test/support) do
      File.mkdir_p!(Path.join(root, path))
    end

    File.write!(Path.join(root, "AGENTS.md"), resident_rules())
    File.write!(Path.join(root, "lib/sample.ex"), "defmodule Example.Sample do\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepts a zero-finding tree without a baseline", %{root: root} do
    report = AgentCodeNCheck.check(root: root, base_baseline: :missing)

    assert report == %{
             "schema" => "agent-facing-code-navigation-report",
             "status" => "pass",
             "navigation_baseline_remaining" => 0,
             "findings" => [],
             "errors" => []
           }

    assert AgentCodeNCheck.human_output(report) ==
             "agent_code_n.check: PASS navigation baseline remaining: 0"
  end

  test "N-01 reports logical symbols and expansion changes the exact identity", %{root: root} do
    write_source(root, "lib/alpha.ex", "defmodule Example.Alpha do\n  def shared(:a), do: :a\nend\n")
    write_source(root, "lib/beta.ex", "defmodule Example.Beta do\n  def shared(:b), do: :b\nend\n")

    findings = findings(root)
    duplicate = Enum.find(findings, &String.starts_with?(&1, "N-01|function|shared|"))
    write_baseline(root, findings)
    assert AgentCodeNCheck.check(root: root, base_baseline: :missing)["status"] == "pass"

    write_source(root, "lib/gamma.ex", "defmodule Example.Gamma do\n  def shared(:c), do: :c\nend\n")
    expanded = AgentCodeNCheck.check(root: root, base_baseline: :missing)

    assert Enum.any?(expanded["errors"], &String.starts_with?(&1, "baseline.unregistered: N-01|function|shared|"))
    assert "baseline.stale: #{duplicate}" in expanded["errors"]
  end

  test "N-01 scans module, type, and fixture declarations by category", %{root: root} do
    write_source(
      root,
      "lib/first.ex",
      "defmodule Example.First.Shared do\n  @type token :: atom()\nend\n"
    )

    write_source(
      root,
      "lib/second.ex",
      "defmodule Example.Second.Shared do\n  @opaque token :: atom()\nend\n"
    )

    write_source(
      root,
      "test/support/fixture_one.exs",
      "defmodule SymphonyElixir.TestSupport.FixtureOne do\n  def seed, do: :ok\nend\n"
    )

    write_source(
      root,
      "test/support/fixture_two.exs",
      "defmodule SymphonyElixir.TestSupport.FixtureTwo do\n  def seed, do: :ok\nend\n"
    )

    duplicates = findings(root) |> Enum.filter(&String.starts_with?(&1, "N-01|"))

    assert Enum.any?(duplicates, &String.starts_with?(&1, "N-01|module|shared|"))
    assert Enum.any?(duplicates, &String.starts_with?(&1, "N-01|type|token|"))
    assert Enum.any?(duplicates, &String.starts_with?(&1, "N-01|fixture|seed|"))
  end

  test "N-03 applies lowercase, underscore, and each finite plural transform", %{root: root} do
    write_source(
      root,
      "lib/names.ex",
      """
      defmodule Example.Widget do
        def job_queue, do: :ok
        def category, do: :ok
        def box, do: :ok
        def item, do: :ok
      end

      defmodule Example.WIDGET do
        def jobqueue, do: :ok
        def categories, do: :ok
        def boxes, do: :ok
        def items, do: :ok
      end
      """
    )

    near_names = findings(root) |> Enum.filter(&String.starts_with?(&1, "N-03|"))

    assert Enum.any?(near_names, &String.starts_with?(&1, "N-03|module|widget|"))
    assert Enum.any?(near_names, &String.starts_with?(&1, "N-03|function|jobqueue|"))
    assert Enum.any?(near_names, &String.starts_with?(&1, "N-03|function|category|"))
    assert Enum.any?(near_names, &String.starts_with?(&1, "N-03|function|box|"))
    assert Enum.any?(near_names, &String.starts_with?(&1, "N-03|function|item|"))
  end

  test "N-05 checks missing, multiple, mismatched, and dotted task modules", %{root: root} do
    write_source(root, "test/no_module.exs", ":ok\n")
    write_source(root, "lib/wrong.ex", "defmodule Example.Other do\nend\n")
    write_source(root, "lib/many.ex", "defmodule Example.Many do\nend\ndefmodule Example.Second do\nend\n")
    write_source(root, "lib/mix/tasks/demo.check.ex", "defmodule Mix.Tasks.Demo.Check do\nend\n")

    n05 = findings(root) |> Enum.filter(&String.starts_with?(&1, "N-05|"))

    assert "N-05|missing-top-level-module|test/no_module.exs" in n05
    assert Enum.any?(n05, &String.starts_with?(&1, "N-05|file-module-mismatch|lib/wrong.ex|"))
    assert Enum.any?(n05, &String.starts_with?(&1, "N-05|multiple-top-level-modules|lib/many.ex|"))
    refute Enum.any?(n05, &String.contains?(&1, "demo.check.ex"))
  end

  test "N-06 rejects date and numbered phase directory segments", %{root: root} do
    for path <- ["docs/2026-10-08", "lib/phase_2", "test/stage-3", "config/batch4"] do
      File.mkdir_p!(Path.join(root, path))
    end

    n06 = findings(root) |> Enum.filter(&String.starts_with?(&1, "N-06|"))

    assert n06 == [
             "N-06|forbidden-directory|config/batch4",
             "N-06|forbidden-directory|docs/2026-10-08",
             "N-06|forbidden-directory|lib/phase_2",
             "N-06|forbidden-directory|test/stage-3"
           ]
  end

  test "N-07 requires explicit Build Run and Test command groups", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), "# Rules\n")

    assert findings(root) |> Enum.filter(&String.starts_with?(&1, "N-07|")) == [
             "N-07|missing-command|Build|mix build",
             "N-07|missing-command|Run|mix symphony.migrate",
             "N-07|missing-command|Test|scripts/check.sh"
           ]
  end

  test "N-08 checks test suffix, support namespace, and product collisions", %{root: root} do
    write_source(root, "lib/service.ex", "defmodule Example.Service do\n  def execute, do: :ok\nend\n")
    write_source(root, "test/bad_test.exs", "defmodule Example.Bad do\nend\n")
    write_source(root, "test/support/helpers.exs", "defmodule Example.Helpers do\nend\n")

    write_source(
      root,
      "test/support/fake.exs",
      "defmodule SymphonyElixir.TestSupport.Fake do\n  def execute, do: :ok\nend\n"
    )

    n08 = findings(root) |> Enum.filter(&String.starts_with?(&1, "N-08|"))

    assert Enum.any?(n08, &String.starts_with?(&1, "N-08|test-module-suffix|test/bad_test.exs:1|"))
    assert Enum.any?(n08, &String.starts_with?(&1, "N-08|support-module-namespace|test/support/helpers.exs:1|"))
    assert Enum.any?(n08, &String.starts_with?(&1, "N-08|helper-product-collision|execute|"))
  end

  test "N-09 checks only the map and executable search entries", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), String.replace(resident_rules(), "[module map](docs/design.md)", "module map"))
    assert "N-09|missing-module-map|AGENTS.md" in findings(root)

    File.write!(Path.join(root, "AGENTS.md"), String.replace(resident_rules(), "`rg -n \"defmodule\" lib test`", "search the code"))
    assert "N-09|missing-rg-command|AGENTS.md" in findings(root)
  end

  test "first initialization accepts only the exact current sorted finding set", %{root: root} do
    write_source(root, "lib/alpha.ex", "defmodule Example.Alpha do\n  def shared, do: :a\nend\n")
    write_source(root, "lib/beta.ex", "defmodule Example.Beta do\n  def shared, do: :b\nend\n")
    current = findings(root)
    write_baseline(root, current)

    report = AgentCodeNCheck.check(root: root, base_baseline: :missing)
    assert report["status"] == "pass"
    assert report["navigation_baseline_remaining"] == length(current)
  end

  test "baseline additions relative to merge base fail", %{root: root} do
    write_source(root, "lib/alpha.ex", "defmodule Example.Alpha do\n  def shared, do: :a\nend\n")
    write_source(root, "lib/beta.ex", "defmodule Example.Beta do\n  def shared, do: :b\nend\n")
    current = findings(root)
    write_baseline(root, current)

    report = AgentCodeNCheck.check(root: root, base_baseline: [])
    assert Enum.any?(report["errors"], &String.starts_with?(&1, "baseline.added: "))
  end

  test "baseline identities may relocate without increasing their declaration count", %{root: root} do
    write_source(root, "lib/alpha.ex", "defmodule Example.Alpha do\n  def shared, do: :a\nend\n")
    write_source(root, "lib/beta.ex", "defmodule Example.Beta do\n  def shared, do: :b\nend\n")
    base = findings(root)

    write_source(root, "lib/alpha.ex", "\ndefmodule Example.Alpha do\n  def shared, do: :a\nend\n")
    write_baseline(root, findings(root))

    assert AgentCodeNCheck.check(root: root, base_baseline: base)["status"] == "pass"
  end

  test "baseline identities reject expanded declaration counts", %{root: root} do
    write_source(root, "lib/alpha.ex", "defmodule Example.Alpha do\n  def shared, do: :a\nend\n")
    write_source(root, "lib/beta.ex", "defmodule Example.Beta do\n  def shared, do: :b\nend\n")
    base = findings(root)

    write_source(root, "lib/gamma.ex", "defmodule Example.Gamma do\n  def shared, do: :c\nend\n")
    write_baseline(root, findings(root))

    report = AgentCodeNCheck.check(root: root, base_baseline: base)
    assert Enum.any?(report["errors"], &String.starts_with?(&1, "baseline.expanded: "))
  end

  test "stale entries and invalid schemas fail", %{root: root} do
    write_baseline(root, ["N-01|function|gone|lib/gone.ex:1,lib/gone.ex:2"])
    assert Enum.any?(AgentCodeNCheck.check(root: root, base_baseline: :missing)["errors"], &String.starts_with?(&1, "baseline.stale: "))

    File.write!(Path.join(root, "config/agent_code_navigation_baseline.yml"), "schema: invalid\n")

    assert AgentCodeNCheck.check(root: root, base_baseline: :missing)["errors"] == [
             "baseline.schema: expected a YAML list of finding identities"
           ]
  end

  test "removing a finding and its baseline together reaches hard mode", %{root: root} do
    write_source(root, "lib/alpha.ex", "defmodule Example.Alpha do\n  def shared, do: :a\nend\n")
    write_source(root, "lib/beta.ex", "defmodule Example.Beta do\n  def shared, do: :b\nend\n")
    old_findings = findings(root)
    write_baseline(root, old_findings)

    File.rm!(Path.join(root, "lib/beta.ex"))
    File.rm!(Path.join(root, "config/agent_code_navigation_baseline.yml"))

    report = AgentCodeNCheck.check(root: root, base_baseline: old_findings)
    assert report["status"] == "pass"
    assert report["navigation_baseline_remaining"] == 0
  end

  test "empty baseline files are rejected and findings stay sorted", %{root: root} do
    File.write!(Path.join(root, "config/agent_code_navigation_baseline.yml"), "[]\n")
    first = AgentCodeNCheck.check(root: root, base_baseline: :missing)
    second = AgentCodeNCheck.check(root: root, base_baseline: :missing)

    assert "baseline.schema: empty baseline must be deleted" in first["errors"]
    assert first["findings"] == Enum.sort(first["findings"])
    assert first == second
  end

  defp findings(root), do: AgentCodeNCheck.check(root: root, base_baseline: :missing)["findings"]

  defp write_source(root, path, content) do
    full_path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  defp write_baseline(root, findings) do
    File.write!(Path.join(root, "config/agent_code_navigation_baseline.yml"), Jason.encode!(findings))
  end

  defp resident_rules do
    """
    ### Build

    Run `mix build`.

    ### Run

    Run `mix symphony.migrate`.

    ### Test

    Run `scripts/check.sh`.

    Use the [module map](docs/design.md) and `rg -n "defmodule" lib test`.
    """
  end

  test "deleting the baseline while findings remain fails", %{root: root} do
    write_source(root, "lib/alpha.ex", "defmodule Example.Alpha do\n  def shared, do: :a\nend\n")
    write_source(root, "lib/beta.ex", "defmodule Example.Beta do\n  def shared, do: :b\nend\n")
    current = findings(root)
    write_baseline(root, current)
    File.rm!(Path.join(root, "config/agent_code_navigation_baseline.yml"))

    report = AgentCodeNCheck.check(root: root, base_baseline: current)

    assert report["status"] == "fail"
    assert Enum.any?(report["errors"], &String.starts_with?(&1, "baseline.unregistered: "))
  end
end

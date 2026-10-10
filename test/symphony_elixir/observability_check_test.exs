defmodule SymphonyElixir.ObservabilityCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ObservabilityCheck

  test "passes a compliant tree without a baseline" do
    with_fixture(
      """
      defmodule Fixture do
        require Logger
        def emit, do: Logger.info("ready", event: "fixture.ready")
      end
      """,
      nil,
      fn root ->
        report = ObservabilityCheck.check(root: root, base_baseline: :missing)
        assert report["status"] == "pass"
        assert report["baseline_remaining"] == 0
        assert ObservabilityCheck.human_output(report) == "observability baseline remaining: 0"
      end
    )
  end

  test "fails a new violation and ignores alternate exemption files" do
    with_fixture("defmodule Fixture do\n  require Logger\n  def emit, do: Logger.info(\"free text\")\nend\n", nil, fn root ->
      File.write!(Path.join(root, "config/observability_allowlist.yml"), "allow: everything\n")
      first = ObservabilityCheck.check(root: root, base_baseline: :missing)
      second = ObservabilityCheck.check(root: root, base_baseline: :missing)
      assert first == second
      assert first["status"] == "fail"
      assert Enum.any?(first["errors"], &String.starts_with?(&1, "unbaselined finding:"))
    end)
  end

  test "rejects malformed, duplicate, and stale baseline entries" do
    with_fixture("defmodule Fixture do\nend\n", "findings: []\n", fn root ->
      assert error_matching?(root, "baseline must contain exactly")
    end)

    duplicate = """
    schema: observability-baseline
    findings:
      - path: lib/fixture.ex
        identifier: logger.info:abc
        reason: legacy
      - path: lib/fixture.ex
        identifier: logger.info:abc
        reason: legacy
    """

    with_fixture("defmodule Fixture do\nend\n", duplicate, fn root ->
      assert error_matching?(root, "duplicate baseline entry:")
    end)

    stale = """
    schema: observability-baseline
    findings:
      - path: lib/fixture.ex
        identifier: logger.info:abc
        reason: legacy
    """

    with_fixture("defmodule Fixture do\nend\n", stale, fn root ->
      assert error_matching?(root, "stale baseline entry:")
    end)
  end

  test "accepts one exact sorted baseline and reports deterministic output" do
    source = "defmodule Fixture do\n  require Logger\n  def emit, do: Logger.info(\"free text\")\nend\n"

    with_fixture(source, nil, fn root ->
      finding = ObservabilityCheck.check(root: root, base_baseline: :missing)["findings"] |> List.first()
      baseline = Jason.encode!(%{"schema" => "observability-baseline", "findings" => [finding]})
      File.write!(Path.join(root, "config/observability_baseline.yml"), baseline)

      outputs = for _ <- 1..2, do: ObservabilityCheck.check(root: root, base_baseline: [finding])
      assert Enum.uniq(outputs) |> length() == 1
      assert hd(outputs)["status"] == "pass"
      assert ObservabilityCheck.human_output(hd(outputs)) == "observability baseline remaining: 1"
    end)
  end

  test "detects silent error tuple and rescue success branches" do
    source = """
    defmodule Fixture do
      def tuple(value) do
        case value do
          {:error, _reason} -> :ok
          value -> value
        end
      end

      def rescued do
        raise "boom"
      rescue
        _error -> false
      end
    end
    """

    with_fixture(source, nil, fn root ->
      findings = ObservabilityCheck.check(root: root, base_baseline: :missing)["findings"]
      assert Enum.any?(findings, &String.starts_with?(&1["identifier"], "silent_error_branch:"))
      assert Enum.any?(findings, &String.starts_with?(&1["identifier"], "silent_rescue:"))
    end)
  end

  test "A writer refreshes a path-only move and is byte-idempotent" do
    with_observability_git_fixture(fn root ->
      File.rename!(Path.join(root, "lib/fixture.ex"), Path.join(root, "lib/moved.ex"))

      assert ObservabilityCheck.write_observability_baseline(root: root)["baseline_write"] == "written"
      baseline_path = Path.join(root, "config/observability_baseline.yml")
      first = File.read!(baseline_path)
      assert first =~ "lib/moved.ex"
      assert ObservabilityCheck.write_observability_baseline(root: root)["baseline_write"] == "unchanged"
      assert File.read!(baseline_path) == first
      assert ObservabilityCheck.check(root: root)["status"] == "pass"
    end)
  end

  test "B writer and ordinary check reject a semantic count increase without changing bytes" do
    with_observability_git_fixture(fn root ->
      baseline_path = Path.join(root, "config/observability_baseline.yml")
      before = File.read!(baseline_path)
      File.cp!(Path.join(root, "lib/fixture.ex"), Path.join(root, "lib/copy.ex"))

      report = ObservabilityCheck.write_observability_baseline(root: root)
      assert report["status"] == "fail"
      assert report["baseline_write"] == "rejected"
      assert Enum.any?(report["errors"], &String.starts_with?(&1, "baseline.added: "))
      assert File.read!(baseline_path) == before

      write_observability_fixture_baseline(root, report["findings"])
      bypass = ObservabilityCheck.check(root: root)
      assert bypass["status"] == "fail"
      assert Enum.any?(bypass["errors"], &String.starts_with?(&1, "baseline.added: "))
    end)
  end

  test "C writer deletes the baseline when the finding is removed" do
    with_observability_git_fixture(fn root ->
      File.write!(
        Path.join(root, "lib/fixture.ex"),
        "defmodule Fixture do\n  require Logger\n  def emit, do: Logger.info(\"ready\", event: \"fixture.ready\")\nend\n"
      )

      report = ObservabilityCheck.write_observability_baseline(root: root)
      assert report["status"] == "pass"
      assert report["baseline_write"] == "deleted"
      refute File.exists?(Path.join(root, "config/observability_baseline.yml"))
      assert ObservabilityCheck.check(root: root)["status"] == "pass"
    end)
  end

  test "writer rejects unavailable merge-base history without changing bytes" do
    with_observability_git_fixture(fn root ->
      path = Path.join(root, "config/observability_baseline.yml")
      before = File.read!(path)
      observability_git!(root, ["update-ref", "-d", "refs/remotes/origin/main"])

      report = ObservabilityCheck.write_observability_baseline(root: root)

      assert report["status"] == "fail"
      assert report["baseline_write"] == "rejected"
      assert Enum.any?(report["errors"], &String.starts_with?(&1, "baseline.merge_base:"))
      assert File.read!(path) == before
    end)
  end

  defp error_matching?(root, prefix) do
    root
    |> then(&ObservabilityCheck.check(root: &1, base_baseline: :missing))
    |> Map.fetch!("errors")
    |> Enum.any?(&String.starts_with?(&1, prefix))
  end

  defp with_fixture(source, baseline, fun) do
    root = Path.join(System.tmp_dir!(), "observability-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "lib/fixture.ex"), source)
    if is_binary(baseline), do: File.write!(Path.join(root, "config/observability_baseline.yml"), baseline)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp with_observability_git_fixture(fun) do
    source = "defmodule Fixture do\n  require Logger\n  def emit, do: Logger.info(\"free text\")\nend\n"

    with_fixture(source, nil, fn root ->
      findings = ObservabilityCheck.check(root: root, base_baseline: :missing)["findings"]
      write_observability_fixture_baseline(root, findings)
      observability_git!(root, ["init", "-q"])
      observability_git!(root, ["add", "."])

      observability_git!(root, [
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "commit",
        "-qm",
        "Observability baseline fixture"
      ])

      observability_git!(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      observability_git!(root, ["checkout", "-qb", "topic-observability"])
      fun.(root)
    end)
  end

  defp write_observability_fixture_baseline(root, findings) do
    document = %{"schema" => "observability-baseline", "findings" => findings}
    File.write!(Path.join(root, "config/observability_baseline.yml"), Jason.encode!(document, pretty: true) <> "\n")
  end

  defp observability_git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end

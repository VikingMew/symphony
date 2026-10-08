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
        report = ObservabilityCheck.check(root: root)
        assert report["status"] == "pass"
        assert report["baseline_remaining"] == 0
        assert ObservabilityCheck.human_output(report) == "observability baseline remaining: 0"
      end
    )
  end

  test "fails a new violation and ignores alternate exemption files" do
    with_fixture("defmodule Fixture do\n  require Logger\n  def emit, do: Logger.info(\"free text\")\nend\n", nil, fn root ->
      File.write!(Path.join(root, "config/observability_allowlist.yml"), "allow: everything\n")
      first = ObservabilityCheck.check(root: root)
      second = ObservabilityCheck.check(root: root)
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
      finding = ObservabilityCheck.check(root: root)["findings"] |> List.first()
      baseline = Jason.encode!(%{"schema" => "observability-baseline", "findings" => [finding]})
      File.write!(Path.join(root, "config/observability_baseline.yml"), baseline)

      outputs = for _ <- 1..2, do: ObservabilityCheck.check(root: root)
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
      findings = ObservabilityCheck.check(root: root)["findings"]
      assert Enum.any?(findings, &String.starts_with?(&1["identifier"], "silent_error_branch:"))
      assert Enum.any?(findings, &String.starts_with?(&1["identifier"], "silent_rescue:"))
    end)
  end

  defp error_matching?(root, prefix) do
    root
    |> then(&ObservabilityCheck.check(root: &1))
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
end

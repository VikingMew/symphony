defmodule Mix.Tasks.Docs.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Docs.Check

  setup do
    root = Path.join(System.tmp_dir!(), "docs-check-task-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/sample.ex"), "defmodule Sample do\nend\n")
    File.write!(Path.join(root, "docs/README.md"), "| [sample.md](sample.md) | sample |\n")
    write_d_fixture(root)
    original = File.cwd!()
    File.cd!(root)

    on_exit(fn ->
      File.cd!(original)
      File.rm_rf!(root)
    end)

    Mix.Task.reenable("docs.check")
    %{root: root}
  end

  test "accepts indexed metadata with a resolvable owner" do
    write_doc(valid_doc())
    output = capture_io(fn -> assert nil == Check.run([]) end)
    assert output =~ "PASS docs/sample.md"
    assert output =~ "docs.check: 1 passed, 1 skipped, 0 failed"
    assert length(Regex.scan(~r/^D baseline: 0 remaining$/m, output)) == 1
  end

  test "rejects a missing required metadata field with a localized finding" do
    write_doc(String.replace(valid_doc(), "status: current\n", ""))

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/docs.check failed with 1 document/, fn -> Check.run([]) end
      end)

    assert output =~ "FAIL docs/sample.md"
    assert output =~ "missing required field: status"
  end

  test "D-01 rejects a missing root AGENTS.md with localized evidence" do
    File.rm!("AGENTS.md")
    output = capture_d_failure()
    assert output =~ "D-01 AGENTS.md target=repository governance file expected=regular file actual=missing"
  end

  test "D-03 rejects missing or extra resident quality commands" do
    File.write!("AGENTS.md", String.replace(File.read!("AGENTS.md"), "scripts/unit.sh", "scripts/e2e.sh"))
    output = capture_d_failure()
    assert output =~ "D-03 AGENTS.md target=Quality Gates commands"
    assert output =~ ~s(actual=["scripts/check.sh", "scripts/e2e.sh", "scripts/dialyzer.sh"])
  end

  test "D-03 rejects missing and non-executable quality scripts" do
    File.rm!("scripts/unit.sh")
    File.chmod!("scripts/dialyzer.sh", 0o644)
    output = capture_d_failure()
    assert output =~ "D-03 scripts/unit.sh target=quality gate script expected=regular executable file actual=missing"
    assert output =~ "D-03 scripts/dialyzer.sh target=quality gate script expected=executable actual=not executable"
  end

  test "D-03 rejects CI command drift" do
    File.write!(
      ".github/workflows/make-all.yml",
      String.replace(File.read!(".github/workflows/make-all.yml"), "scripts/unit.sh", "scripts/e2e.sh")
    )

    output = capture_d_failure()
    assert output =~ "D-03 .github/workflows/make-all.yml target=jobs.*.steps.run"
    assert output =~ ~s(actual=["scripts/check.sh", "scripts/dialyzer.sh", "scripts/e2e.sh"])
  end

  test "D-04 rejects missing README structure and entry commands" do
    File.write!("README.md", "## Quick Start\n\nNo command.\n\n## Development\n\nNo command.\n")
    output = capture_d_failure()
    assert output =~ "D-04 README.md target=structure or module map"
    assert output =~ "D-04 README.md target=startup entry command"
    assert output =~ "D-04 README.md target=development entry command"
  end

  defp valid_doc do
    """
    ---
    title: Sample
    genre: reference
    domain: tests
    status: current
    language: en
    owner: Sample
    updated: 2026-09-27
    ---

    # Sample
    """
  end

  defp write_doc(content), do: File.write!("docs/sample.md", content)

  defp capture_d_failure do
    capture_io(:stderr, fn ->
      assert_raise Mix.Error, ~r/docs.check failed with/, fn -> Check.run([]) end
    end)
  end

  defp write_d_fixture(root) do
    File.mkdir_p!(Path.join(root, "scripts"))
    File.mkdir_p!(Path.join(root, ".github/workflows"))

    File.write!(
      Path.join(root, "AGENTS.md"),
      "## Quality Gates\n\n- `scripts/check.sh`\n- `scripts/unit.sh`\n- `scripts/dialyzer.sh`\n"
    )

    File.write!(
      Path.join(root, "README.md"),
      "## Quick Start\n\n`mise exec -- mix setup`\n\n## Project Layout\n\n- lib\n\n## Development\n\n`mise exec -- mix test`\n"
    )

    Enum.each(~w(check unit dialyzer), fn name ->
      path = Path.join(root, "scripts/#{name}.sh")
      File.write!(path, "#!/usr/bin/env bash\n")
      File.chmod!(path, 0o755)
    end)

    File.write!(
      Path.join(root, ".github/workflows/make-all.yml"),
      "jobs:\n  check:\n    steps:\n      - run: scripts/check.sh\n  unit:\n    steps:\n      - run: scripts/unit.sh\n  dialyzer:\n    steps:\n      - run: scripts/dialyzer.sh\n"
    )
  end
end

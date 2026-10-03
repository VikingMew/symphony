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
end

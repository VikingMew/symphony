defmodule Mix.Tasks.PrBody.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrBody.Check
  import ExUnit.CaptureIO

  @template """
  #### Summary

  - <!-- Describe a completed change. -->

  #### Test Plan

  - [ ] <!-- Record a validation command or check. -->

  Fixes SYM-XX
  """

  @valid_body """
  #### Summary

  - Added the handoff renderer.

  #### Test Plan

  - [x] `mix test`

  Fixes SYM-21
  """

  setup do
    Mix.Task.reenable("pr_body.check")
    :ok
  end

  test "prints help" do
    assert capture_io(fn -> Check.run(["--help"]) end) =~ "mix pr_body.check --file"
  end

  test "accepts only the required sections and exact closing reference" do
    in_temp_repo(fn ->
      write_contract_and_entry!()
      File.write!("body.md", @valid_body)
      assert capture_io(fn -> Check.run(["--file", "body.md"]) end) =~ "PR body format OK"
    end)
  end

  test "rejects drift between the docs contract and GitHub entry" do
    in_temp_repo(fn ->
      write_contract_and_entry!()
      File.write!(".github/pull_request_template.md", "drift")
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/has drifted from the canonical template/, fn ->
        Check.run(["--file", "body.md"])
      end
    end)
  end

  test "rejects missing and out-of-order required headings" do
    assert_invalid(String.replace(@valid_body, "#### Summary", "#### Notes"), "Missing required heading: #### Summary")

    reversed = """
    #### Test Plan

    - [x] checked

    #### Summary

    - changed

    Fixes SYM-21
    """

    assert_invalid(reversed, "Required headings are out of order")
  end

  test "rejects empty sections, placeholders, and invalid list shapes" do
    assert_invalid(
      String.replace(@valid_body, "- Added the handoff renderer.", ""),
      "Section cannot be empty: #### Summary"
    )

    assert_invalid(
      String.replace(@valid_body, "- Added the handoff renderer.", "<!-- todo -->"),
      "placeholder comments"
    )

    assert_invalid(
      String.replace(@valid_body, "- Added the handoff renderer.", "plain text"),
      "bullet item: #### Summary"
    )
    assert_invalid(String.replace(@valid_body, "- [x] `mix test`", "- ran tests"), "checkbox item: #### Test Plan")
  end

  test "rejects missing, imprecise, duplicate, and misplaced Linear closing references" do
    assert_invalid(String.replace(@valid_body, "Fixes SYM-21", ""), "Missing exact Linear closing reference")
    assert_invalid(
      String.replace(@valid_body, "Fixes SYM-21", "Fixes #SYM-21"),
      "Missing exact Linear closing reference"
    )
    assert_invalid(@valid_body <> "\nFixes SYM-22\n", "exactly one Linear closing reference")
    assert_invalid(@valid_body <> "\ntrailing prose\n", "must be the final independent line")
  end

  test "requires the docs-owned contract" do
    in_temp_repo(fn ->
      File.write!("body.md", @valid_body)
      assert_raise Mix.Error, ~r/Unable to read PR body contract/, fn -> Check.run(["--file", "body.md"]) end
    end)
  end

  defp assert_invalid(body, expected) do
    in_temp_repo(fn ->
      write_contract_and_entry!()
      File.write!("body.md", body)

      output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn -> Check.run(["--file", "body.md"]) end
        end)

      assert output =~ expected
    end)
  end

  defp write_contract_and_entry! do
    File.mkdir_p!("docs")
    File.mkdir_p!(".github")

    File.write!("docs/pull-request-body.md", """
    contract
    <!-- pr-body-template:start -->
    #{String.trim(@template)}
    <!-- pr-body-template:end -->
    """)

    File.write!(".github/pull_request_template.md", String.trim(@template))
  end

  defp in_temp_repo(fun) do
    root = Path.join(System.tmp_dir!(), "pr-body-check-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end
end

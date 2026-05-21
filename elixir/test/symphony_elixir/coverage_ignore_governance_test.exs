defmodule SymphonyElixir.CoverageIgnoreGovernanceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MixProject

  @allowed_categories [
    "protocol/process boundary",
    "storage boundary",
    "presentation shell",
    "missing-test debt"
  ]

  test "coverage ignore groups have categories and removal conditions" do
    groups = MixProject.coverage_ignore_groups()

    assert groups != []

    for group <- groups do
      assert group.category in @allowed_categories
      assert is_binary(group.remove_when)
      assert String.trim(group.remove_when) != ""
      assert is_map(group.exit_slices)
      assert is_list(group.modules)
      assert group.modules != []

      for module <- group.modules do
        assert is_binary(Map.fetch!(group.exit_slices, module))
        assert String.trim(Map.fetch!(group.exit_slices, module)) != ""
      end
    end
  end

  test "coverage ignore_modules is exactly the governed module list" do
    project = MixProject.project()
    ignore_modules = get_in(project, [:test_coverage, :ignore_modules])
    governed_modules = Enum.flat_map(MixProject.coverage_ignore_groups(), & &1.modules)

    assert ignore_modules == governed_modules
    refute SymphonyElixir.Shell in ignore_modules
    refute SymphonyElixir.Payload in ignore_modules
    refute SymphonyElixir.Redaction in ignore_modules
    refute SymphonyElixir.StateName in ignore_modules
    refute SymphonyElixir.Text in ignore_modules
    refute SymphonyElixir.NumberFormat in ignore_modules
    refute SymphonyElixir.Codex.DynamicTool in ignore_modules
  end
end

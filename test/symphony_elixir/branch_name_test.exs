defmodule SymphonyElixir.BranchNameTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.BranchName

  test "accepts Linear branch names and rejects unsafe refs" do
    assert {:ok, "feature/ccr-3"} = BranchName.validate("feature/ccr-3")
    assert {:ok, "fix_123.audit"} = BranchName.validate("fix_123.audit")

    assert {:error, {:invalid_linear_branch_name, :non_ascii}} =
             BranchName.validate("功能/修复")

    assert {:error, {:invalid_linear_branch_name, :whitespace}} =
             BranchName.validate("feature/ccr 3")

    assert {:error, {:invalid_linear_branch_name, {:unsafe_fragment, ".."}}} =
             BranchName.validate("feature/../../bad")

    assert {:error, {:invalid_linear_branch_name, :leading_dash}} =
             BranchName.validate("-bad")

    assert {:error, :missing_linear_branch_name} = BranchName.validate(nil)
  end
end

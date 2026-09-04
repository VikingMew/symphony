defmodule SymphonyElixir.Codex.RefinementQualityGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.RefinementQualityGate

  @valid """
  ## Goal
  Ship the gate.

  ## Scope
  Validate refinement output.

  ## Out of scope
  Semantic review.

  ## Acceptance criteria
  - Invalid output is rejected.

  ## Validation
  Run unit tests.

  ## Open questions
  None
  """

  test "accepts a complete description and explicit resolved-question values" do
    assert :ok = RefinementQualityGate.validate(@valid)
    assert :ok = RefinementQualityGate.validate(String.replace(@valid, "None", "无"))

    assert :ok =
             RefinementQualityGate.validate(String.replace(@valid, "## Open questions\nNone", "## Unresolved Questions\n- NONE"))
  end

  test "reports every missing or empty required section in stable order" do
    description = """
    ## Goal

    ## Scope
    Included.

    ## Acceptance criteria
    prose only
    """

    assert {:error, violations} = RefinementQualityGate.validate(description)

    assert violations == [
             violation("missing_required_section", "Add a non-empty `Goal` section."),
             violation("missing_required_section", "Add a non-empty `Out of scope` section."),
             violation("missing_required_section", "Add a non-empty `Validation` section."),
             violation(
               "missing_testable_acceptance",
               "Add a non-placeholder Markdown list item under `Acceptance criteria`."
             )
           ]
  end

  test "matches every ambiguous marker without regard to case" do
    for marker <- ["[needs clarification]", "[todo]", "todo:", "tBd", "???"] do
      assert "ambiguous_marker" in codes(RefinementQualityGate.validate(@valid <> marker))
    end
  end

  test "aggregates ambiguous, context, unresolved-question, and acceptance failures" do
    description =
      @valid
      |> String.replace("- Invalid output is rejected.", "- [TODO]")
      |> String.replace("None", "Who owns this?\n- Who validates it?")
      |> Kernel.<>("\n[context required]\n???")

    assert {:error, violations} = RefinementQualityGate.validate(description)

    assert Enum.map(violations, & &1.code) == [
             "ambiguous_marker",
             "implicit_context_reference",
             "unresolved_questions",
             "missing_testable_acceptance"
           ]
  end

  test "requires a non-empty candidate description" do
    assert RefinementQualityGate.validate(nil) ==
             {:error,
              [
                violation(
                  "missing_required_section",
                  "Provide a non-empty candidate description."
                )
              ]}

    assert RefinementQualityGate.validate("  ") == RefinementQualityGate.validate(nil)
  end

  test "recognizes ordered Markdown acceptance items and exact section boundaries" do
    description =
      @valid
      |> String.replace("- Invalid output is rejected.", "1. Invalid output is rejected.")
      |> String.replace("## Validation", "### Validation ###")

    assert :ok = RefinementQualityGate.validate(description)
  end

  defp codes({:error, violations}), do: Enum.map(violations, & &1.code)
  defp violation(code, message), do: %{code: code, message: message}
end

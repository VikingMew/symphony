defmodule SymphonyElixir.Codex.RefinementQualityGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.RefinementQualityGate

  @valid """
  ## Goal
  Ship the gate.

  ## Owning design docs
  - `docs/codex-linear-task-refinement-workflow-design.md` — update required: yes

  Change classification: behavior/architecture
  Design sync: required

  ## Scope
  Update docs/codex-linear-task-refinement-workflow-design.md and validate refinement output.

  ## Out of scope
  Semantic review.

  ## Acceptance criteria
  - docs/codex-linear-task-refinement-workflow-design.md documents the gate and invalid output is rejected.

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
             violation("missing_required_section", "Add a non-empty `Owning design docs` section."),
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
      |> String.replace(
        "- docs/codex-linear-task-refinement-workflow-design.md documents the gate and invalid output is rejected.",
        "- [TODO]"
      )
      |> String.replace("None", "Who owns this?\n- Who validates it?")
      |> Kernel.<>("\n[context required]\n???")

    assert {:error, violations} = RefinementQualityGate.validate(description)

    assert Enum.map(violations, & &1.code) == [
             "design_sync_missing_from_acceptance",
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

  test "requires valid owning-design declarations" do
    missing_fields = String.replace(@valid, "Change classification: behavior/architecture\nDesign sync: required", "Owner: pending")

    assert codes(RefinementQualityGate.validate(missing_fields)) == [
             "missing_change_classification",
             "missing_design_sync"
           ]

    invalid =
      @valid
      |> String.replace("behavior/architecture", "feature")
      |> String.replace("Design sync: required", "Design sync: maybe")

    assert codes(RefinementQualityGate.validate(invalid)) == [
             "invalid_change_classification",
             "invalid_design_sync"
           ]
  end

  test "rejects behavior changes without required owner synchronization" do
    no_owner =
      @valid
      |> String.replace("- `docs/codex-linear-task-refinement-workflow-design.md` — update required: yes", "No owner: false")
      |> String.replace("Design sync: required", "Design sync: not required")

    assert codes(RefinementQualityGate.validate(no_owner)) == [
             "behavior_design_sync_not_required",
             "missing_owning_design"
           ]
  end

  test "requires no-owner registration plans in scope and acceptance criteria" do
    description =
      @valid
      |> String.replace("- `docs/codex-linear-task-refinement-workflow-design.md` — update required: yes", "No owner: true")
      |> String.replace("Update docs/codex-linear-task-refinement-workflow-design.md and validate refinement output.", "Owner registration plan: register a new L3 owner.")
      |> String.replace("- docs/codex-linear-task-refinement-workflow-design.md documents the gate and invalid output is rejected.", "- Invalid output is rejected.")

    assert codes(RefinementQualityGate.validate(description)) == [
             "missing_owner_registration_plan",
             "design_sync_missing_from_acceptance"
           ]
  end

  test "requires listed owners in scope and acceptance criteria when sync is required" do
    description =
      @valid
      |> String.replace("Update docs/codex-linear-task-refinement-workflow-design.md and validate refinement output.", "Validate refinement output.")
      |> String.replace("- docs/codex-linear-task-refinement-workflow-design.md documents the gate and invalid output is rejected.", "- Invalid output is rejected.")

    assert RefinementQualityGate.validate(description) ==
             {:error,
              [
                violation(
                  "design_sync_missing_from_scope",
                  "Reference every listed owning design in `Scope`."
                ),
                violation(
                  "design_sync_missing_from_acceptance",
                  "Reference every listed owning design in `Acceptance criteria`."
                )
              ]}
  end

  test "accepts explicit no-owner and non-behavior declarations" do
    no_owner =
      @valid
      |> String.replace("- `docs/codex-linear-task-refinement-workflow-design.md` — update required: yes", "No owner: true")
      |> String.replace("Update docs/codex-linear-task-refinement-workflow-design.md and validate refinement output.", "Owner registration plan: register a new L3 owner.")
      |> String.replace(
        "- docs/codex-linear-task-refinement-workflow-design.md documents the gate and invalid output is rejected.",
        "- Owner registration plan: register the new L3 owner and reject invalid output."
      )

    assert :ok = RefinementQualityGate.validate(no_owner)

    non_behavior =
      @valid
      |> String.replace("- `docs/codex-linear-task-refinement-workflow-design.md` — update required: yes\n\n", "")
      |> String.replace("behavior/architecture", "non-behavior")
      |> String.replace("Design sync: required", "Design sync: not required\nReason: Test-only wording change.")
      |> String.replace("Update docs/codex-linear-task-refinement-workflow-design.md and validate refinement output.", "Validate refinement output.")
      |> String.replace("- docs/codex-linear-task-refinement-workflow-design.md documents the gate and invalid output is rejected.", "- Invalid output is rejected.")

    assert :ok = RefinementQualityGate.validate(non_behavior)
    assert "missing_design_sync_reason" in codes(RefinementQualityGate.validate(String.replace(non_behavior, "Reason: Test-only wording change.\n", "")))
  end

  defp codes({:error, violations}), do: Enum.map(violations, & &1.code)
  defp violation(code, message), do: %{code: code, message: message}
end

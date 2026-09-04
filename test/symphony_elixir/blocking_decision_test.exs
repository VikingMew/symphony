defmodule SymphonyElixir.BlockingDecisionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.BlockingDecision
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous = Application.get_env(:symphony_elixir, :persistence_module)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    FakePersistence.put_issues([
      %{
        identifier: "SYM-15",
        tracker_issue_id: "linear-15",
        blocking_decision: nil,
        no_progress_streak: 0
      }
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :persistence_module, previous),
        else: Application.delete_env(:symphony_elixir, :persistence_module)
    end)

    :ok
  end

  test "normalizes only canonical empty values and the legacy none token" do
    assert BlockingDecision.normalize_blocker(nil) == nil
    assert BlockingDecision.normalize_blocker("") == nil
    assert BlockingDecision.normalize_blocker("   ") == nil
    assert BlockingDecision.normalize_blocker("  NoNe  ") == nil
    assert BlockingDecision.normalize_blocker("None for handoff") == "None for handoff"

    assert BlockingDecision.normalize_blocker("missing deploy permission") ==
             "missing deploy permission"
  end

  test "two completed no-progress runs persist a blocking decision without changing attempts" do
    assert {:streak, 1} = BlockingDecision.advance_no_progress("SYM-15", "run-1")
    assert {:blocked, decision} = BlockingDecision.advance_no_progress("SYM-15", "run-2")
    assert decision["reason"] == "no_progress"
    assert decision["run_id"] == "run-2"

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.no_progress_streak == 2
    assert issue.blocking_decision == decision

    assert :ok = BlockingDecision.clear("SYM-15")
    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.no_progress_streak == 0
    assert issue.blocking_decision == nil
  end

  test "classifies typed implementation handoff failures as terminal" do
    assert BlockingDecision.terminal_handoff_failure?({:implementation_handoff_failed, :pull_request_conflict})

    assert BlockingDecision.terminal_handoff_failure?({:implementation_handoff_field_required, "comment"})

    refute BlockingDecision.terminal_handoff_failure?(:capacity_exhausted)
  end

  test "persists policy-prohibited validation as ordinary reported blocker evidence" do
    evidence =
      "required image build conflicts with the container-engine validation policy"

    assert {:ok, decision} =
             BlockingDecision.decide("SYM-15", :reported_blocker, evidence, "run-policy")

    assert decision["reason"] == "reported_blocker"
    assert decision["evidence"] == evidence
    assert decision["transition_status"] == "pending"

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.blocking_decision == decision
  end
end

defmodule SymphonyElixir.BlockingDecisionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.BlockingDecision
  alias SymphonyElixir.Persistence.IssueRecord
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous = Application.get_env(:symphony_elixir, :persistence_module)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    FakePersistence.put_issues([
      %{
        identifier: "SYM-15",
        tracker_issue_id: "linear-15",
        state: "Refining",
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

  test "builds one canonical state and run scoped decision" do
    decision =
      BlockingDecision.new(
        :pr_review,
        "review findings",
        "run-17",
        "Ready to Merge",
        %{"pr_url" => "https://github.com/acme/app/pull/17"},
        %{"review_job_id" => "review-17"}
      )

    assert decision["reason"] == "pr_review"
    assert decision["evidence"] == "review findings"
    assert decision["run_id"] == "run-17"
    assert decision["origin_state"] == "Ready to Merge"
    assert decision["references"] == %{"pr_url" => "https://github.com/acme/app/pull/17"}
    assert decision["review_job_id"] == "review-17"
    assert decision["comment_status"] == "pending"
    assert decision["transition_status"] == "pending"
  end

  test "requires both expected Linear state and latest persisted run" do
    pending = BlockingDecision.new(:reported_blocker, "blocked", "run-1", "In Progress")

    assert BlockingDecision.validity(pending, "In Progress", "run-1") == :valid
    assert BlockingDecision.validity(pending, "Todo", "run-1") == {:stale, :state_mismatch}

    assert BlockingDecision.validity(pending, "In Progress", "run-2") ==
             {:stale, :run_superseded}

    completed = Map.put(pending, "transition_status", "completed")
    assert BlockingDecision.validity(completed, "Blocked", "run-1") == :valid
    assert BlockingDecision.validity(completed, "In Progress", "run-1") == {:stale, :state_mismatch}
  end

  test "two completed no-progress runs persist a blocking decision without changing attempts" do
    assert {:streak, 1} = BlockingDecision.advance_no_progress("SYM-15", "run-1")

    first_run = FakePersistence.get_issue_by_identifier("SYM-15")
    assert first_run.state == "Refining"
    assert first_run.no_progress_streak == 1
    assert first_run.blocking_decision == nil

    assert {:blocked, decision} =
             BlockingDecision.advance_no_progress("SYM-15", "run-2", %{
               "quality_gate" => "refinement_quality_gate_failed"
             })

    assert decision["reason"] == "no_progress"
    assert decision["run_id"] == "run-2"
    assert decision["origin_state"] == "Refining"

    assert decision["references"] == %{
             "quality_gate" => "refinement_quality_gate_failed"
           }

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.state == "Refining"
    assert issue.no_progress_streak == 2
    assert issue.blocking_decision == decision

    # A successful review transition invokes the same clear path.
    assert :ok = BlockingDecision.clear("SYM-15")
    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.no_progress_streak == 0
    assert issue.blocking_decision == nil
  end

  test "persists policy-prohibited validation as ordinary reported blocker evidence" do
    evidence =
      "required image build conflicts with the container-engine validation policy"

    assert {:ok, decision} =
             BlockingDecision.decide("SYM-15", :reported_blocker, evidence, "run-policy")

    assert decision["reason"] == "reported_blocker"
    assert decision["evidence"] == evidence
    assert decision["origin_state"] == "Refining"
    assert decision["transition_status"] == "pending"

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.blocking_decision == decision
  end

  test "scope migration preserves the JSON decision columns and adds origin state" do
    migration =
      File.read!("priv/repo/migrations/20260926000000_scope_blocking_decisions_to_state_and_run.exs")

    assert migration =~ "SET blocking_decision = jsonb_set("
    assert migration =~ "'{origin_state}'"
    assert migration =~ "to_jsonb(state)"
    assert migration =~ "WHERE blocking_decision IS NOT NULL"

    fields = IssueRecord.__schema__(:fields)
    assert :blocking_decision in fields
    assert :no_progress_streak in fields
  end
end

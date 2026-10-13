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
        snapshot: %{"state" => "Refining"},
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

    structured = BlockingDecision.new(:failure_retries_exhausted, %{detail: "failed"}, "run-18", "In Progress")
    assert structured["evidence"] == %{detail: "failed"}
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

    assert BlockingDecision.validity(Map.delete(pending, "origin_state"), "In Progress", "run-1") ==
             {:stale, :missing_scope}

    assert BlockingDecision.validity(Map.delete(pending, "run_id"), "In Progress", "run-1") ==
             {:stale, :missing_scope}
  end

  test "two completed no-progress runs persist a blocking decision without changing attempts" do
    assert {:streak, 1} = BlockingDecision.advance_no_progress("SYM-15", "run-1", "Refining")

    first_run = FakePersistence.get_issue_by_identifier("SYM-15")
    assert first_run.snapshot["state"] == "Refining"
    assert first_run.no_progress_streak == 1
    assert first_run.blocking_decision == nil

    assert {:blocked, decision} =
             BlockingDecision.advance_no_progress("SYM-15", "run-2", "Refining", %{
               "quality_gate" => "refinement_quality_gate_failed"
             })

    assert decision["reason"] == "no_progress"
    assert decision["run_id"] == "run-2"
    assert decision["origin_state"] == "Refining"

    assert decision["references"] == %{
             "quality_gate" => "refinement_quality_gate_failed"
           }

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.snapshot["state"] == "Refining"
    assert issue.no_progress_streak == 2
    assert issue.blocking_decision == decision

    # A successful review transition invokes the same clear path.
    assert {:ok,
            {:cleared,
             %{
               issue_id: "linear-15",
               run_id: "run-2"
             }}} = BlockingDecision.clear("SYM-15")

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.no_progress_streak == 0
    assert issue.blocking_decision == nil
    assert {:ok, :already_cleared} = BlockingDecision.clear("SYM-15")
  end

  test "manual clear preserves the issue snapshot and run history" do
    decision = BlockingDecision.new(:reported_blocker, "operator action", "run-clear", "In Progress")
    issue = FakePersistence.get_issue_by_identifier("SYM-15")

    {:ok, _issue} =
      FakePersistence.update_issue(issue, %{
        blocking_decision: decision,
        no_progress_streak: 4
      })

    run = %{id: "run-clear", issue_identifier: "SYM-15", status: "blocked"}
    FakePersistence.put_runs([run])

    assert {:ok, {:cleared, %{issue_id: "linear-15", run_id: "run-clear"}}} =
             BlockingDecision.clear("SYM-15")

    cleared = FakePersistence.get_issue_by_identifier("SYM-15")
    assert cleared.blocking_decision == nil
    assert cleared.no_progress_streak == 0
    assert cleared.snapshot == %{"state" => "Refining"}
    assert FakePersistence.list_runs_for_issue("SYM-15") == [run]
  end

  test "persists policy-prohibited validation as ordinary reported blocker evidence" do
    evidence =
      "required image build conflicts with the container-engine validation policy"

    assert {:ok, decision} =
             BlockingDecision.decide("SYM-15", :reported_blocker, evidence, "run-policy", "Refining")

    assert decision["reason"] == "reported_blocker"
    assert decision["evidence"] == evidence
    assert decision["origin_state"] == "Refining"
    assert decision["transition_status"] == "pending"

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.blocking_decision == decision
  end

  test "stale clear atomically resets the decision and no-progress streak" do
    decision = BlockingDecision.new(:failure_retries_exhausted, "failed", "run-old", "In Progress")
    issue = FakePersistence.get_issue_by_identifier("SYM-15")

    {:ok, _issue} =
      FakePersistence.update_issue(issue, %{
        blocking_decision: decision,
        no_progress_streak: 2
      })

    assert {:ok, event} =
             BlockingDecision.clear_stale(
               "SYM-15",
               decision,
               "candidate_selection",
               :state_mismatch,
               FakePersistence
             )

    assert event.payload["cause"] == "state_mismatch"
    assert event.payload["run_id"] == "run-old"

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.blocking_decision == nil
    assert issue.no_progress_streak == 0
  end

  test "stale clear does not reset a replacement decision or streak" do
    old = BlockingDecision.new(:failure_retries_exhausted, "old", "run-old", "In Progress")
    replacement = BlockingDecision.new(:reported_blocker, "new", "run-new", "Todo")
    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    {:ok, _issue} = FakePersistence.update_issue(issue, %{blocking_decision: old, no_progress_streak: 2})

    Application.put_env(:symphony_elixir, :blocking_decision_cas_hook, fn ->
      current = FakePersistence.get_issue_by_identifier("SYM-15")
      {:ok, _issue} = FakePersistence.update_issue(current, %{blocking_decision: replacement, no_progress_streak: 7})
      Application.delete_env(:symphony_elixir, :blocking_decision_cas_hook)
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :blocking_decision_cas_hook) end)

    assert :replaced =
             BlockingDecision.clear_stale(
               "SYM-15",
               old,
               "candidate_selection",
               :state_mismatch,
               FakePersistence
             )

    issue = FakePersistence.get_issue_by_identifier("SYM-15")
    assert issue.blocking_decision == replacement
    assert issue.no_progress_streak == 7
    assert FakePersistence.list_events(event_type: "issue.blocking_decision_cleared") == []
  end

  test "equivalent post-cutover legacy fixtures are stale on their first scoped claim" do
    fixtures = [
      {"SYM-130", "In Progress", "Todo", "run-130"},
      {"SYM-136", "Blocked", "Ready", "run-136"},
      {"SYM-138", "In Progress", "Todo", "run-138"},
      {"SYM-139", "Blocked", "Ready", "run-139"}
    ]

    Enum.each(fixtures, fn {_identifier, persisted_state, live_state, run_id} ->
      legacy = %{
        "reason" => "legacy blocker",
        "evidence" => "synthetic equivalent fixture",
        "run_id" => run_id,
        "decided_at" => "2026-09-24T00:00:00Z",
        "transition_status" => "pending"
      }

      post_cutover = Map.put(legacy, "origin_state", persisted_state)

      assert BlockingDecision.validity(post_cutover, live_state, run_id) ==
               {:stale, :state_mismatch}
    end)
  end

  test "blocking decision scope remains JSON-backed without new issue columns" do
    fields = IssueRecord.__schema__(:fields)
    assert :blocking_decision in fields
    assert :no_progress_streak in fields
    assert :origin_state not in fields
    assert :state not in fields
  end
end

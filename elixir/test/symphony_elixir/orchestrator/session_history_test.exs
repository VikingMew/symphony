defmodule SymphonyElixir.Orchestrator.SessionHistoryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.SessionHistory

  test "initial run history is shaped without orchestrator process state" do
    issue = %Issue{id: "issue-1", identifier: "CCR-1", state: "In Progress"}

    assert [
             %{
               event: :run_started,
               label: "Run started",
               detail: "Started from In Progress",
               source: :system,
               severity: :info,
               metadata: %{issue_id: "issue-1", issue_identifier: "CCR-1", state: "In Progress", attempt: 2}
             }
           ] = SessionHistory.initial(issue, 2, "local", now: ~U[2026-05-22 00:00:00Z])
  end

  test "system progress coalesces adjacent updates by source phase and operation" do
    entry = %{session_history: [], session_history_total_count: 0}

    updated =
      entry
      |> SessionHistory.append_system(%{phase: "workspace_bootstrap", operation: "git_clone", status: "started", detail: "start"})
      |> SessionHistory.append_system(%{phase: "workspace_bootstrap", operation: "git_clone", status: "completed", detail: "done"})

    assert %{session_history_total_count: 2, session_history: [event]} = updated
    assert event.event == :system_progress
    assert event.label == "Git clone"
    assert event.detail == "done"
    assert event.metadata.coalesced_event_count == 2
  end
end

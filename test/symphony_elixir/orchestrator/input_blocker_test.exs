defmodule SymphonyElixir.Orchestrator.InputBlockerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.InputBlocker

  test "formats any explicit blocked reason without classifying it" do
    outcome = %{reason: "blocked_on_push_auth", detail: %{action: "refresh credentials"}}

    assert InputBlocker.summary(outcome) =~ "blocked_on_push_auth"
    assert InputBlocker.summary(%{outcome | reason: "brand_new_reason"}) =~ "brand_new_reason"
  end

  test "builds a blocked entry from a running issue snapshot" do
    now = ~U[2026-05-22 00:00:00Z]

    entry =
      InputBlocker.entry(
        "issue-1",
        %{
          identifier: "CCR-5",
          issue: %{state: "In Progress"},
          worker_host: "local",
          workspace_path: "/tmp/work",
          session_id: "session-1",
          session_history: [%{event: "codex_starting"}]
        },
        %{reason: "blocked_on_push_auth", detail: "refresh credentials", references: %{pr: 41}},
        now
      )

    assert entry.issue_id == "issue-1"
    assert entry.identifier == "CCR-5"
    assert entry.state == "In Progress"
    assert entry.worker_host == "local"
    assert entry.workspace_path == "/tmp/work"
    assert entry.session_id == "session-1"
    assert entry.blocked_at == now
    assert entry.reason == "blocked_on_push_auth"
    assert entry.detail == "refresh credentials"
    assert entry.references == %{pr: 41}
    assert entry.session_history == [%{event: "codex_starting"}]
    assert entry.session_history_total_count == 1
  end
end

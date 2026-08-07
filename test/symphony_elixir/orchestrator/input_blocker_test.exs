defmodule SymphonyElixir.Orchestrator.InputBlockerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.InputBlocker

  test "classifies Codex input and approval requirements as blocked" do
    payload = %{"method" => "turn/input_required", "params" => %{"reason" => "needs operator"}}

    assert {:blocked, :turn_input_required, ^payload} = InputBlocker.blocked_reason({:turn_input_required, payload})
    assert {:blocked, :turn_input_required, ^payload} = InputBlocker.blocked_reason(payload)
    assert {:blocked, :approval_required, %{}} = InputBlocker.blocked_reason(%{method: "turn/approval_required"})
    assert InputBlocker.blocked?({:approval_required, %{}})
    assert InputBlocker.summary({:turn_input_required, payload}) =~ "waiting for operator input"
    assert InputBlocker.summary({:approval_required, %{}}) =~ "waiting for Codex approval"
    assert InputBlocker.event({:approval_required, %{}}) == :approval_required
    assert InputBlocker.label({:approval_required, %{}}) == "Approval required"
    assert InputBlocker.label(:turn_input_required) == "Input required"
    assert InputBlocker.detail({:approval_required, %{}}) == "Codex is waiting for approval before it can continue."
    assert InputBlocker.detail({:turn_input_required, %{}}) == "turn blocked: waiting for user input"
  end

  test "leaves normal agent failures retryable" do
    refute InputBlocker.blocked?({:workspace_hook_timeout, "project_bootstrap", 1_000, %{}})
    assert InputBlocker.blocked_reason({:codex_startup_failed, %{}}) == :retryable
    assert InputBlocker.blocked_reason(%{"method" => "turn/completed"}) == :retryable
    assert InputBlocker.summary(:ok) == "not blocked"
    assert InputBlocker.detail(:ok) == "not blocked"
    assert InputBlocker.event(:ok) == :blocked
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
        {:approval_required, %{}},
        now
      )

    assert entry.issue_id == "issue-1"
    assert entry.identifier == "CCR-5"
    assert entry.state == "In Progress"
    assert entry.worker_host == "local"
    assert entry.workspace_path == "/tmp/work"
    assert entry.session_id == "session-1"
    assert entry.blocked_at == now
    assert entry.reason == :approval_required
    assert entry.detail == "Codex is waiting for approval before it can continue."
    assert entry.session_history == [%{event: "codex_starting"}]
    assert entry.session_history_total_count == 1
  end
end

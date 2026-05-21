defmodule SymphonyElixir.RunSummaryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunSummary

  test "derives compact run summary from useful timeline rows" do
    history = [
      %{source: :agent, event: "codex.update", label: "Codex", detail: "dynamic tool call requested (linear_task_read)", severity: :info, low_signal: false, metadata: %{"session_id" => "thread-1"}},
      %{source: :agent, event: "codex.update", label: "Codex", detail: "agent message streaming: Finished the task.", severity: :info, low_signal: false, metadata: %{}},
      %{source: :linear, event: "linear.state_transition", label: "Linear", detail: "In Progress -> In Review", severity: :info, low_signal: false, metadata: %{}},
      %{source: :agent, event: "codex.update", label: "Codex", detail: "ignored", severity: :info, low_signal: true, metadata: %{"session_id" => "ignored"}}
    ]

    summary = RunSummary.summarize(%{status: "completed", attempt: 3}, history)

    assert summary.outcome == "completed attempt 3"
    assert summary.final_message == "Finished the task."
    assert summary.last_codex_detail == "agent message streaming: Finished the task."
    assert summary.tools == ["linear_task_read x1"]
    assert summary.linear_updates == ["In Progress -> In Review"]
    assert summary.sessions == ["thread-1", "ignored"]
    assert summary.evidence_quality == :complete
  end
end

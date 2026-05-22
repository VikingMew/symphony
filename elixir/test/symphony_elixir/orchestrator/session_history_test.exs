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

  test "append keeps history limit and total count separate" do
    entry = %{session_history: [], session_history_total_count: 0}

    updated =
      entry
      |> SessionHistory.append(:workspace_ready, "Workspace ready", %{workspace_path: "/tmp/a"}, history_limit: 1)
      |> SessionHistory.append(:linear_state_transition, "State changed", %{from_state: "Ready", to_state: "In Progress"}, history_limit: 1)

    assert updated.session_history_total_count == 2
    assert [%{event: :linear_state_transition, detail: "Ready -> In Progress", source: :linear}] = updated.session_history
  end

  test "system events derive label severity source and sanitized metadata" do
    now = ~U[2026-05-22 00:00:00Z]

    event =
      SessionHistory.event(
        :startup_failed,
        "System",
        %{
          phase: "codex_starting",
          source: "worker",
          detail: "failed",
          nested: %{at: now},
          output: String.duplicate("x", 600)
        },
        now: now
      )

    assert event.at == now
    assert event.detail == "startup_failed"
    assert event.severity == :error
    assert event.source == "worker"
    assert event.metadata.nested.at == "2026-05-22T00:00:00Z"
    assert String.ends_with?(event.metadata.output, "...")
    assert String.length(event.metadata.output) == 503
  end

  test "append_system creates non-coalesced warnings for different operations" do
    entry = %{session_history: [], session_history_total_count: 0}

    updated =
      entry
      |> SessionHistory.append_system(%{phase: "workspace_bootstrap", operation: "hook:before_run", status: "warning"})
      |> SessionHistory.append_system(%{phase: "workspace_bootstrap", operation: "git_fetch", status: :warning})

    assert updated.session_history_total_count == 2
    assert Enum.map(updated.session_history, & &1.label) == ["Before run", "Git fetch"]
    assert Enum.all?(updated.session_history, &(&1.severity == :warning))
  end

  test "integrates codex updates through the shared update reducer" do
    update = %{
      event: :codex_event,
      timestamp: ~U[2026-05-22 00:00:00Z],
      payload: %{"method" => "turn/started", "params" => %{"turn" => %{"id" => "turn-1"}}}
    }

    {entry, token_delta} = SessionHistory.integrate_codex_update(%{}, update)

    assert token_delta.total_tokens == 0
    assert [%{detail: "turn started (turn-1)"}] = entry.session_history
  end
end

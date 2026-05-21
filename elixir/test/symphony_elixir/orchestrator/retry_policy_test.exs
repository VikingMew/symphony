defmodule SymphonyElixir.Orchestrator.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.RetryPolicy

  test "prepare_retry normalizes attempt, delay, and metadata from previous retry" do
    previous_timer = make_ref()

    prepared =
      RetryPolicy.prepare_retry(
        "issue-1",
        nil,
        %{error: "new error"},
        %{
          attempt: 2,
          timer_ref: previous_timer,
          identifier: "MT-1",
          worker_host: "worker-a",
          workspace_path: "/tmp/work"
        },
        120_000
      )

    assert prepared.attempt == 3
    assert prepared.delay_ms == 40_000
    assert prepared.old_timer_ref == previous_timer
    assert prepared.identifier == "MT-1"
    assert prepared.error == "new error"
    assert prepared.worker_host == "worker-a"
    assert prepared.workspace_path == "/tmp/work"
  end

  test "continuation retry uses the short first-attempt delay" do
    prepared =
      RetryPolicy.prepare_retry(
        "issue-2",
        1,
        %{identifier: "MT-2", delay_type: :continuation},
        %{attempt: 0},
        120_000
      )

    assert prepared.attempt == 1
    assert prepared.delay_ms == 1_000
    assert prepared.delay_type == :continuation
  end

  test "pop_retry_attempt ignores stale tokens and returns metadata for current token" do
    current_token = make_ref()
    stale_token = make_ref()

    attempts = %{
      "issue-3" => %{
        attempt: 4,
        retry_token: current_token,
        identifier: "MT-3",
        error: "boom",
        worker_host: "worker-b",
        workspace_path: "/tmp/work"
      }
    }

    assert RetryPolicy.pop_retry_attempt(attempts, "issue-3", stale_token) == :missing

    assert {:ok, 4, metadata, remaining} =
             RetryPolicy.pop_retry_attempt(attempts, "issue-3", current_token)

    assert metadata == %{
             identifier: "MT-3",
             error: "boom",
             worker_host: "worker-b",
             workspace_path: "/tmp/work"
           }

    assert remaining == %{}
  end

  test "stall_decision only stalls entries with codex activity older than timeout" do
    now = ~U[2026-05-21 00:00:10Z]

    running_entry = %{
      identifier: "MT-4",
      session_id: "thread-4",
      retry_attempt: 2,
      last_codex_timestamp: ~U[2026-05-21 00:00:00Z]
    }

    assert {:stalled, decision} = RetryPolicy.stall_decision("issue-4", running_entry, now, 5_000)
    assert decision.identifier == "MT-4"
    assert decision.session_id == "thread-4"
    assert decision.elapsed_ms == 10_000
    assert decision.attempt == 3
    assert decision.metadata.error == "stalled for 10000ms without codex activity"

    assert RetryPolicy.stall_decision("issue-5", %{last_codex_timestamp: nil}, now, 5_000) == :active
  end
end

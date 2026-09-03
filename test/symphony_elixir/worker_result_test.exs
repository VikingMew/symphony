defmodule SymphonyElixir.WorkerResultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkerResult

  test "accepts ordered passed, failed, timed-out, and not-run gate evidence" do
    gates = [
      gate("compile", "passed", 0),
      gate("test", "failed", 2, "two failures"),
      gate("integration", "timed_out", nil, "timeout reached"),
      gate("handoff-check", "not_run", nil, "earlier required gate failed")
    ]

    assert {:ok, %{"gates" => ^gates}} = WorkerResult.validate(summary(gates))
  end

  test "rejects oversized, path-bearing, secret-bearing, and malformed evidence" do
    assert {:error, {:invalid_worker_summary, "gate count exceeds 32"}} =
             WorkerResult.validate(summary(List.duplicate(gate("gate", "passed", 0), 33)))

    assert {:error, {:invalid_worker_summary, message}} =
             WorkerResult.validate(summary([gate("test", "failed", 1, "/tmp/worker/output.log")]))

    assert message =~ "filesystem path"

    assert {:error, {:invalid_worker_summary, secret_message}} =
             WorkerResult.validate(summary([gate("test", "failed", 1, "token=super-secret")]))

    assert secret_message =~ "secret-bearing"
    assert {:error, {:invalid_worker_summary, _}} = WorkerResult.validate(%{})
  end

  test "allows lightweight progress events without a summary" do
    assert WorkerResult.validate_event("task.progress", %{"phase" => "execution_started"}) == {:ok, nil}
  end

  test "requires a valid summary for terminal task events" do
    valid_summary = summary([])

    for event_type <- ["task.completed", "task.failed", "task.cancelled"] do
      assert WorkerResult.validate_event(event_type, %{}) ==
               {:error, {:invalid_worker_summary, "summary must be an object"}}

      assert {:ok, ^valid_summary} = WorkerResult.validate_event(event_type, %{"summary" => valid_summary})
    end
  end

  defp summary(gates) do
    %{
      "phase" => "validation",
      "outcome" => "failed",
      "reason" => "non_zero",
      "occurred_at" => "2026-08-28T10:00:00Z",
      "started_at" => "2026-08-28T09:59:00Z",
      "finished_at" => "2026-08-28T10:00:00Z",
      "duration_ms" => 60_000,
      "source_revision" => "abc123",
      "runtime" => %{"image_digest" => "sha256:abc", "worker_source_revision" => "def456"},
      "validation_status" => "failed",
      "gates" => gates,
      "handoff" => %{"branch" => "feature", "failed_step" => "validation"}
    }
  end

  defp gate(name, status, exit_code, detail \\ nil) do
    %{
      "name" => name,
      "status" => status,
      "exit_code" => exit_code,
      "duration_ms" => 50,
      "timeout_ms" => 1_000,
      "failure_detail" => detail
    }
  end
end

defmodule SymphonyElixir.WorkerResultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkerResult

  test "publishes the producer and receiver limits" do
    assert WorkerResult.limits() == %{
             max_gates: 32,
             max_text: 512,
             max_detail: 2_048,
             max_source_output: 4_096
           }
  end

  test "normalizes worker-local paths before retaining bounded head and tail evidence" do
    limits = WorkerResult.limits()

    detail =
      "command=scripts/check.sh HEAD /tmp/worker/check.log " <>
        String.duplicate("中", limits.max_detail) <>
        " TAIL C:\\worker\\validation.log"

    normalized = WorkerResult.normalize_detail(detail)

    assert String.length(normalized) == limits.max_detail
    assert normalized =~ "command=scripts/check.sh HEAD [worker-local path]"
    assert normalized =~ "... (truncated) ..."
    assert String.ends_with?(normalized, " TAIL [worker-local path]")
    refute normalized =~ "/tmp/worker"
    refute normalized =~ "C:\\worker"

    assert {:ok, _summary} =
             WorkerResult.validate(summary([gate("check", "failed", 1, normalized)]))
  end

  test "accepts ordered passed, failed, timed-out, and not-run gate evidence" do
    gates = [
      gate("compile", "passed", 0),
      gate("test", "failed", 2, "two failures"),
      gate("integration", "timed_out", nil, "timeout reached"),
      gate("handoff-check", "not_run", nil, "earlier required gate failed")
    ]

    assert {:ok, %{"gates" => ^gates}} = WorkerResult.validate(summary(gates))
  end

  test "accepts the explicit blocked terminal outcome" do
    blocked = summary([]) |> Map.put("outcome", "blocked") |> Map.put("reason", "handoff_failed")

    assert {:ok, %{"outcome" => "blocked", "reason" => "handoff_failed"}} =
             WorkerResult.validate(blocked)
  end

  test "accepts pending validation with required gates that were not run" do
    pending =
      summary([gate("scripts/check.sh", "not_run", nil, "validation did not start")])
      |> Map.put("reason", "handoff_failed")
      |> Map.put("validation_status", "pending")
      |> Map.put("detail", ~s({"reason":["handoff_failed","missing_handoff"],"status":"failed"}))

    assert {:ok, validated} = WorkerResult.validate(pending)
    assert validated["validation_status"] == "pending"
    assert [%{"status" => "not_run"}] = validated["gates"]
    assert Jason.decode!(validated["detail"])["reason"] == ["handoff_failed", "missing_handoff"]
  end

  test "rejects oversized, path-bearing, secret-bearing, and malformed evidence" do
    assert {:error, {:invalid_worker_summary, "gate count exceeds 32"}} =
             WorkerResult.validate(summary(List.duplicate(gate("gate", "passed", 0), 33)))

    assert {:error, {:invalid_worker_summary, message}} =
             WorkerResult.validate(summary([gate("test", "failed", 1, "/tmp/worker/output.log")]))

    assert message =~ "filesystem path"

    assert {:error, {:invalid_worker_summary, oversized_message}} =
             WorkerResult.validate(summary([gate("test", "failed", 1, String.duplicate("x", 2_049))]))

    assert oversized_message == "gate 0: failure_detail exceeds 2048 characters"

    assert {:error, {:invalid_worker_summary, secret_message}} =
             WorkerResult.validate(summary([gate("test", "failed", 1, "token=super-secret")]))

    assert secret_message =~ "secret-bearing"
    assert {:error, {:invalid_worker_summary, _}} = WorkerResult.validate(%{})
  end

  test "allows lightweight progress events without a summary" do
    assert WorkerResult.validate_event("task.progress", %{"phase" => "execution_started"}) == {:ok, nil}
  end

  test "accepts typed source preparation timeout evidence" do
    timeout =
      summary([])
      |> Map.put("phase", "source_preparation")
      |> Map.put("reason", "source_preparation_timeout")
      |> Map.put("failure_evidence", %{
        "phase" => "fetch_failed",
        "command_status" => "timed_out",
        "duration_ms" => 1_001,
        "output" => "fetch progress"
      })

    assert {:ok, validated} = WorkerResult.validate(timeout)
    assert validated["failure_evidence"]["phase"] == "fetch_failed"
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

  test "accepts only bounded closed evidence for non-timeout source preparation failures" do
    failed =
      summary([])
      |> Map.put("phase", "source_preparation")
      |> Map.put("reason", "source_preparation_failed")
      |> Map.put("failure_evidence", %{
        "phase" => "checkout_failed",
        "command_status" => "failed",
        "operation" => "task_branch_merge",
        "detail" => "merge conflict"
      })

    assert {:ok, validated} = WorkerResult.validate(failed)
    assert validated["failure_evidence"]["operation"] == "task_branch_merge"

    assert {:error, {:invalid_worker_summary, _message}} =
             WorkerResult.validate(put_in(failed, ["failure_evidence", "phase"], "merge_failed"))

    assert {:error, {:invalid_worker_summary, _message}} =
             WorkerResult.validate(Map.delete(failed, "failure_evidence"))
  end
end

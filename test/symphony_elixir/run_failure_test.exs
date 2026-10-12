defmodule SymphonyElixir.RunFailureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunFailure

  test "publishes the closed application vocabulary without historical unknown" do
    assert RunFailure.classifications() == [
             "environment_unavailable",
             "source_preparation_timeout",
             "external_dependency_timeout",
             "budget_exhausted",
             "contract_violation",
             "worker_process_termination",
             "assignment_expired",
             "validation_failed",
             "runtime_failure",
             "codex_upstream_capacity",
             "codex_turn_failed",
             "cancelled",
             "operator_stopped"
           ]
  end

  test "classifies local typed causes and keeps raw fields in evidence" do
    assert_failure(
      RunFailure.classify(%File.Error{reason: :erofs, path: "/workspace", action: "write"}),
      "environment_unavailable",
      %{"action" => "write", "kind" => "file_error", "path" => "/workspace", "reason" => "erofs"}
    )

    assert_failure(
      RunFailure.classify({:source_preparation_timeout, :clone, %{timeout_ms: 1_000}}),
      "source_preparation_timeout",
      %{"phase" => "clone", "timeout_ms" => 1_000}
    )

    assert_failure(
      RunFailure.classify({:linear_api_request, %Req.TransportError{reason: :timeout}}),
      "external_dependency_timeout",
      %{"dependency" => "linear", "operation" => "api_request", "reason" => "timeout"}
    )

    assert RunFailure.classify({:stall_timeout, %{elapsed_ms: 500, timeout_ms: 400}}).classification ==
             "budget_exhausted"

    assert RunFailure.classify({:read_timeout, %{timeout_ms: 400}}).classification == "budget_exhausted"

    assert RunFailure.classify({:failure_retries_exhausted, %{failure_attempt: 3}}).classification ==
             "budget_exhausted"

    assert RunFailure.classify(:missing_handoff).classification == "contract_violation"
    assert RunFailure.classify({:handoff_failed, %{detail: "missing PR"}}).classification == "contract_violation"

    assert RunFailure.classify({:invalid_worker_summary, "missing phase"}).classification ==
             "contract_violation"

    assert RunFailure.classify({:port_exit, 137}).evidence == %{"exit_code" => 137, "kind" => "port_exit"}
    assert RunFailure.classify({:signal, :sigkill}).classification == "worker_process_termination"
    assert RunFailure.classify(:oom).classification == "worker_process_termination"
    assert RunFailure.classify({:assignment_loss, %{phase: :lease}}).classification == "worker_process_termination"

    assert_failure(
      RunFailure.classify({:assignment_expired, %{phase: :lease, code: "invalid_worker_summary"}}),
      "assignment_expired",
      %{"code" => "invalid_worker_summary", "phase" => "lease", "reason" => "assignment_expired"}
    )

    assert RunFailure.classify({:validation_result, 2}).classification == "validation_failed"

    assert RunFailure.classify({:validation_failed, %{gate: "unit", timeout_ms: 1_000}}).classification ==
             "validation_failed"

    assert RunFailure.classify({:codex_upstream_capacity, %{codexErrorInfo: %{type: "capacity"}}}).classification ==
             "codex_upstream_capacity"

    assert RunFailure.classify({:codex_turn_failed, %{codexErrorInfo: %{type: "turn_error"}}}).classification ==
             "codex_turn_failed"

    assert RunFailure.classify({:claim_transition_failure, {:ecto, :stale}}).evidence == %{
             "detail" => ["ecto", "stale"],
             "reason" => "claim_transition_failure"
           }

    assert is_binary(RunFailure.classify({:claim_transition_failure, make_ref()}).evidence["detail"])

    assert RunFailure.classify({:cancelled, %{action: :cancel_task}}).classification == "cancelled"

    assert RunFailure.classify({:agent_domain_failure, %{reason: "worker_error"}}).classification ==
             "runtime_failure"

    assert RunFailure.classify({:operator_stopped, %{action: :force_stop, run_kind: :nap}}).evidence == %{
             "action" => "force_stop",
             "run_kind" => "nap"
           }
  end

  test "classifies validated worker summaries" do
    assert :completed == RunFailure.from_worker_summary("task.completed", %{})
    assert :completed == RunFailure.from_worker_summary("task.failed", %{"outcome" => "succeeded"})

    assert RunFailure.from_worker_summary("task.cancelled", worker_summary("cancelled", "cancelled")).classification ==
             "cancelled"

    checkout = worker_summary("failed", "timed_out") |> Map.put("phase", "checkout")
    assert RunFailure.from_worker_summary("task.failed", checkout).classification == "source_preparation_timeout"

    source_failure = source_preparation_failure_summary()
    assert_source_preparation_mapping(source_failure)

    topology_evidence = %{
      "phase" => "checkout_failed",
      "operation" => "merge_base_exhausted",
      "repository_shallow" => false
    }

    topology =
      worker_summary("blocked", "source_topology_invalid")
      |> Map.put("phase", "source_preparation")
      |> Map.put("failure_evidence", topology_evidence)

    assert %RunFailure{classification: "source_preparation_timeout", evidence: ^topology_evidence} =
             RunFailure.from_worker_summary("task.failed", topology)

    assert RunFailure.from_worker_summary(
             "task.failed",
             worker_summary("failed", "workspace_unavailable")
           ).classification == "environment_unavailable"

    validation = worker_summary("failed", "non_zero") |> Map.put("validation_status", "failed")
    assert RunFailure.from_worker_summary("task.failed", validation).classification == "validation_failed"

    validation_timeout = worker_summary("failed", "timed_out") |> Map.put("validation_status", "timed_out")
    assert RunFailure.from_worker_summary("task.failed", validation_timeout).classification == "validation_failed"

    assert RunFailure.from_worker_summary(
             "task.failed",
             worker_summary("failed", "execution_capability_unavailable")
           ).classification == "runtime_failure"

    upstream =
      worker_summary("failed", "codex_upstream_capacity")
      |> Map.put("codexErrorInfo", %{"type" => "capacity"})

    assert RunFailure.from_worker_summary("task.failed", upstream).classification == "codex_upstream_capacity"
    assert RunFailure.from_worker_summary("task.failed", worker_summary("failed", "codex_turn_failed")).classification == "codex_turn_failed"
    assert RunFailure.from_worker_summary("task.failed", worker_summary("blocked", "worker_error")).classification == "runtime_failure"
  end

  test "has no catch-all for untagged causes" do
    untyped = {:untyped, "opaque"}
    historical = "unknown"

    assert_raise FunctionClauseError, fn -> classify_dynamic(untyped) end
    assert_raise FunctionClauseError, fn -> classify_dynamic(historical) end
  end

  defp worker_summary(outcome, reason) do
    %{
      "phase" => "codex",
      "outcome" => outcome,
      "reason" => reason,
      "detail" => "bounded detail",
      "validation_status" => "pending",
      "gates" => []
    }
  end

  defp assert_failure(failure, classification, evidence) do
    assert failure.classification == classification
    assert failure.evidence == evidence
  end

  defp source_preparation_failure_summary do
    worker_summary("failed", "source_preparation_failed")
    |> Map.put("phase", "source_preparation")
    |> Map.put("failure_evidence", %{
      "phase" => "checkout_failed",
      "command_status" => "failed",
      "operation" => "task_branch_merge",
      "detail" => "merge conflict"
    })
  end

  defp assert_source_preparation_mapping(summary) do
    assert RunFailure.from_worker_summary("task.failed", summary).classification == "source_preparation_timeout"
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp classify_dynamic(cause), do: :erlang.apply(RunFailure, :classify, [cause])
end

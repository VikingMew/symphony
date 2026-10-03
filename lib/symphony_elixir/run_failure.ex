defmodule SymphonyElixir.RunFailure do
  @moduledoc """
  Closed classification and structured evidence for persisted run failures.

  `unknown` is intentionally absent from the application vocabulary. It is
  reserved for the forward-only migration and SQLite cutover importer.
  """

  @enforce_keys [:classification, :evidence]
  defstruct [:classification, :evidence]

  @classifications ~w(
    environment_unavailable
    source_preparation_timeout
    external_dependency_timeout
    budget_exhausted
    contract_violation
    worker_process_termination
    validation_failed
    runtime_failure
    codex_upstream_capacity
    codex_turn_failed
    cancelled
    operator_stopped
  )

  @type classification :: String.t()

  @type t :: %__MODULE__{classification: String.t(), evidence: map()}

  @spec classifications() :: [String.t()]
  def classifications, do: @classifications

  @spec classify(term()) :: t()
  def classify(%File.Error{reason: reason, path: path, action: action}) do
    new("environment_unavailable", %{kind: "file_error", reason: reason, path: path, action: action})
  end

  def classify({:environment_unavailable, evidence}),
    do: new("environment_unavailable", evidence)

  def classify({:source_preparation_timeout, phase, evidence})
      when phase in [:clone, :fetch, :checkout, "clone", "fetch", "checkout"] do
    new("source_preparation_timeout", Map.put(json_map(evidence), "phase", to_string(phase)))
  end

  def classify({:linear_api_request, %Req.TransportError{reason: :timeout}}) do
    new("external_dependency_timeout", %{
      dependency: "linear",
      operation: "api_request",
      reason: "timeout"
    })
  end

  def classify({:external_dependency_timeout, evidence}),
    do: new("external_dependency_timeout", evidence)

  def classify({:stall_timeout, evidence}), do: new("budget_exhausted", evidence)
  def classify({:read_timeout, evidence}), do: new("budget_exhausted", evidence)
  def classify({:failure_retries_exhausted, evidence}), do: new("budget_exhausted", evidence)
  def classify({:budget_exhausted, evidence}), do: new("budget_exhausted", evidence)

  def classify(:missing_handoff), do: new("contract_violation", %{reason: "missing_handoff"})
  def classify({:handoff_failed, evidence}), do: new("contract_violation", put_reason(evidence, "handoff_failed"))

  def classify({:invalid_worker_summary, detail}) do
    new("contract_violation", %{reason: "invalid_worker_summary", detail: detail})
  end

  def classify({:protocol_gate_failed, evidence}),
    do: new("contract_violation", put_reason(evidence, "protocol_gate_failed"))

  def classify({:port_exit, code}) when is_integer(code),
    do: new("worker_process_termination", %{kind: "port_exit", exit_code: code})

  def classify({:worker_process_termination, evidence}),
    do: new("worker_process_termination", evidence)

  def classify({:signal, signal}),
    do: new("worker_process_termination", %{kind: "signal", signal: signal})

  def classify(:oom), do: new("worker_process_termination", %{kind: "oom"})

  def classify({:assignment_loss, evidence}),
    do: new("worker_process_termination", put_reason(evidence, "assignment_loss"))

  def classify({:validation_failed, evidence}), do: new("validation_failed", evidence)

  def classify({:validation_result, exit_code}) when is_integer(exit_code) and exit_code != 0,
    do: new("validation_failed", %{reason: "non_zero", exit_code: exit_code})

  def classify({:codex_upstream_capacity, evidence}),
    do: new("codex_upstream_capacity", evidence)

  def classify({:codex_turn_failed, evidence}), do: new("codex_turn_failed", evidence)

  def classify({:execution_capability_unavailable, evidence}) do
    new("runtime_failure", put_reason(evidence, "execution_capability_unavailable"))
  end

  def classify({:claim_transition_failure, detail}) do
    new("runtime_failure", %{reason: "claim_transition_failure", detail: json_value(detail)})
  end

  def classify({:agent_domain_failure, evidence}), do: new("runtime_failure", evidence)
  def classify({:operator_domain_failure, evidence}), do: new("runtime_failure", evidence)
  def classify({:blocked, evidence}), do: new("runtime_failure", evidence)
  def classify({:runtime_failure, evidence}), do: new("runtime_failure", evidence)
  def classify({:cancelled, evidence}), do: new("cancelled", evidence)
  def classify({:operator_stopped, evidence}), do: new("operator_stopped", evidence)

  @spec from_worker_summary(String.t(), map()) :: :completed | t()
  def from_worker_summary("task.completed", _summary), do: :completed

  def from_worker_summary("task.cancelled", summary) do
    classify({:cancelled, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"outcome" => "succeeded"}), do: :completed

  def from_worker_summary("task.failed", %{"outcome" => "cancelled"} = summary) do
    classify({:cancelled, summary_evidence(summary)})
  end

  def from_worker_summary(
        "task.failed",
        %{
          "reason" => "source_preparation_timeout",
          "failure_evidence" => %{"phase" => phase} = evidence
        }
      )
      when phase in ["clone_failed", "fetch_failed", "checkout_failed"] do
    new("source_preparation_timeout", evidence)
  end

  def from_worker_summary("task.failed", %{"phase" => phase, "reason" => "timed_out"} = summary)
      when phase in ["clone", "fetch", "checkout"] do
    classify({:source_preparation_timeout, phase, summary_evidence(summary)})
  end

  def from_worker_summary(
        "task.failed",
        %{"phase" => phase, "reason" => "source_preparation_failed"} = summary
      )
      when phase in ["clone", "fetch", "checkout"] do
    classify({:source_preparation_timeout, phase, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "workspace_unavailable"} = summary) do
    classify({:environment_unavailable, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "handoff_failed"} = summary) do
    classify({:handoff_failed, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "missing_handoff"} = summary) do
    classify({:protocol_gate_failed, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "lease_lost"} = summary) do
    classify({:worker_process_termination, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "execution_capability_unavailable"} = summary) do
    classify({:execution_capability_unavailable, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "codex_upstream_capacity"} = summary) do
    classify({:codex_upstream_capacity, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "codex_turn_failed"} = summary) do
    classify({:codex_turn_failed, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"phase" => "codex"} = summary)
      when is_map_key(summary, "codexErrorInfo") do
    classify({:codex_turn_failed, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"validation_status" => status} = summary)
      when status in ["failed", "timed_out"] do
    classify({:validation_failed, validation_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "timed_out"} = summary) do
    classify({:budget_exhausted, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"outcome" => "blocked"} = summary) do
    classify({:blocked, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "worker_error"} = summary) do
    classify({:runtime_failure, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "non_zero"} = summary) do
    classify({:validation_failed, validation_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => "cancelled"} = summary) do
    classify({:cancelled, summary_evidence(summary)})
  end

  def from_worker_summary("task.failed", %{"reason" => reason} = summary)
      when reason in ["in_progress", "completed"] do
    classify({:protocol_gate_failed, summary_evidence(summary) |> Map.put("detail", "terminal failed event carried non-failure reason")})
  end

  @spec reason(t()) :: String.t()
  def reason(%__MODULE__{classification: classification}), do: classification

  @spec evidence(t()) :: map()
  def evidence(%__MODULE__{evidence: evidence}), do: evidence

  @spec terminal_fields(:completed | t()) :: %{failure_reason: String.t() | nil, failure_evidence: map() | nil}
  def terminal_fields(:completed), do: %{failure_reason: nil, failure_evidence: nil}

  def terminal_fields(%__MODULE__{} = failure) do
    %{failure_reason: reason(failure), failure_evidence: evidence(failure)}
  end

  defp new(classification, evidence) when classification in @classifications do
    evidence = json_map(evidence)
    true = map_size(evidence) > 0
    %__MODULE__{classification: classification, evidence: evidence}
  end

  defp summary_evidence(summary) do
    summary
    |> Map.take(~w(phase outcome reason detail validation_status gates handoff codexErrorInfo failure_evidence))
    |> json_map()
  end

  defp validation_evidence(summary) do
    summary
    |> Map.take(~w(phase outcome reason detail validation_status gates))
    |> json_map()
  end

  defp put_reason(evidence, reason), do: evidence |> json_map() |> Map.put_new("reason", reason)

  defp json_map(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), json_value(value)} end)
  defp json_map(value), do: %{"detail" => json_value(value)}

  defp json_value(%_{} = struct), do: struct |> Map.from_struct() |> json_map()
  defp json_value(map) when is_map(map), do: json_map(map)
  defp json_value(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&json_value/1)
  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  defp json_value(value) when is_boolean(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp json_value(value), do: inspect(value, limit: 50, printable_limit: 2_000)
end

defmodule SymphonyElixir.Orchestrator.InputBlocker do
  @moduledoc """
  Classifies Codex results that require operator input instead of retry.
  """

  alias SymphonyElixir.Codex.MessageHumanizer

  @blocked_reasons [:turn_input_required, :approval_required]

  @spec blocked_reason(term()) :: {:blocked, atom(), map()} | :retryable
  def blocked_reason({reason, payload}) when reason in @blocked_reasons and is_map(payload) do
    {:blocked, reason, payload}
  end

  def blocked_reason(%{"method" => method} = payload) when is_binary(method) do
    blocked_reason_from_method(method, payload)
  end

  def blocked_reason(%{method: method} = payload) when is_binary(method) do
    blocked_reason_from_method(method, payload)
  end

  def blocked_reason(reason) when reason in @blocked_reasons do
    {:blocked, reason, %{}}
  end

  def blocked_reason(_reason), do: :retryable

  @spec blocked?(term()) :: boolean()
  def blocked?(reason), do: match?({:blocked, _reason, _payload}, blocked_reason(reason))

  @spec summary(term()) :: String.t()
  def summary(reason) do
    case blocked_reason(reason) do
      {:blocked, :approval_required, payload} ->
        "blocked: waiting for Codex approval #{payload_summary(payload)}"

      {:blocked, :turn_input_required, payload} ->
        "blocked: waiting for operator input #{payload_summary(payload)}"

      :retryable ->
        "not blocked"
    end
    |> String.trim()
  end

  @spec event(term()) :: atom()
  def event(reason) do
    case blocked_reason(reason) do
      {:blocked, event, _payload} -> event
      :retryable -> :blocked
    end
  end

  @spec label(term()) :: String.t()
  def label({:approval_required, _payload}), do: "Approval required"
  def label(:approval_required), do: "Approval required"
  def label(_reason), do: "Input required"

  @spec detail(term()) :: String.t()
  def detail(reason) do
    case blocked_reason(reason) do
      {:blocked, :approval_required, _payload} ->
        "Codex is waiting for approval before it can continue."

      {:blocked, :turn_input_required, _payload} ->
        "turn blocked: waiting for user input"

      :retryable ->
        "not blocked"
    end
  end

  @spec entry(String.t(), map(), term(), DateTime.t()) :: map()
  def entry(issue_id, running_entry, reason, now \\ DateTime.utc_now())
      when is_binary(issue_id) and is_map(running_entry) do
    %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier),
      state: get_in(running_entry, [:issue, Access.key(:state)]),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: Map.get(running_entry, :session_id),
      blocked_at: now,
      reason: event(reason),
      detail: detail(reason),
      session_history: Map.get(running_entry, :session_history, []),
      session_history_total_count: Map.get(running_entry, :session_history_total_count, length(Map.get(running_entry, :session_history, [])))
    }
  end

  defp payload_summary(payload) when is_map(payload) do
    detail = MessageHumanizer.humanize_codex_message(payload)
    if detail == "", do: "", else: "detail=#{inspect(detail)}"
  end

  defp blocked_reason_from_method(method, payload) do
    cond do
      method in ["turn/approval_required"] ->
        {:blocked, :approval_required, payload}

      method in [
        "turn/input_required",
        "turn/needs_input",
        "turn/need_input",
        "turn/request_input",
        "turn/provide_input",
        "mcpServer/elicitation/request",
        "mcp/elicitation/request"
      ] ->
        {:blocked, :turn_input_required, payload}

      true ->
        :retryable
    end
  end
end

defmodule SymphonyElixir.Codex.LinearToolAudit do
  @moduledoc """
  Structured audit events for Symphony-owned restricted Linear tools.
  """

  require Logger

  alias SymphonyElixir.{Payload, Redaction}

  @linear_tools ~w(linear_task_read linear_task_update linear_issue_create create_pull_request handoff)

  @spec linear_tool?(term()) :: boolean()
  def linear_tool?(tool) when tool in @linear_tools, do: true
  def linear_tool?(_tool), do: false

  @spec record(String.t(), term(), map(), keyword()) :: :ok | {:error, term()}
  def record(tool, arguments, response, opts) when is_binary(tool) and is_map(response) do
    if linear_tool?(tool) do
      started_at = Keyword.get(opts, :audit_started_at) || DateTime.utc_now()
      duration_ms = Keyword.get(opts, :audit_duration_ms)

      payload =
        %{
          tool: tool,
          status: status(response),
          profile: Keyword.get(opts, :profile),
          issue_identifier: issue_identifier(opts),
          issue_id: issue_id(opts),
          operator_kind: Keyword.get(opts, :operator_kind),
          run_id: Keyword.get(opts, :run_id),
          session_id: Keyword.get(opts, :session_id),
          thread_id: Keyword.get(opts, :thread_id),
          turn_id: Keyword.get(opts, :turn_id),
          tool_call_id: Keyword.get(opts, :tool_call_id),
          arguments: safe_arguments(arguments),
          result: success_result(response),
          error: failure_error(tool, response),
          started_at: started_at,
          duration_ms: duration_ms,
          message: message(tool, response)
        }
        |> drop_nil_values()

      attrs = %{
        run_id: Keyword.get(opts, :run_id),
        issue_identifier: issue_identifier(opts),
        event_type: "linear.tool_call",
        payload: payload
      }

      opts
      |> Keyword.fetch(:audit_recorder)
      |> record_event(attrs, payload, tool, opts)
    else
      :ok
    end
  end

  def record(_tool, _arguments, _response, _opts), do: :ok

  defp status(%{"success" => true}), do: "success"
  defp status(_response), do: "failure"

  defp message(tool, %{"success" => true}) when tool == "linear_issue_create", do: "Linear issue created"
  defp message(tool, %{"success" => true}), do: "#{tool} succeeded"
  defp message(tool, _response), do: "#{tool} failed"

  defp success_result(%{"success" => true} = response) do
    response
    |> decoded_output()
    |> normalize_success_result()
  end

  defp success_result(_response), do: nil

  defp failure_error(_tool, %{"success" => false} = response) do
    output = decoded_output(response)
    error = if is_map(output), do: Payload.get_any(output, ["error", :error]), else: nil

    %{
      class: error_code(error),
      code: error_code(error),
      retryable: error_retryable(error),
      message: error_message(error, output),
      reason: error_reason(error)
    }
    |> drop_nil_values()
  end

  defp failure_error(_tool, _response), do: nil

  defp normalize_success_result(%{} = output) do
    output
    |> Map.take([
      "id",
      "identifier",
      "title",
      "url",
      "repository",
      "base",
      "head",
      "head_oid",
      "source",
      "accepted",
      "linear_updated",
      "state",
      "issue_update",
      "comment_update",
      "reference_links",
      "requested_state",
      "handoff",
      "issue",
      "workflow"
    ])
    |> Redaction.payload(500)
  end

  defp normalize_success_result(output), do: Redaction.payload(output, 500)

  defp decoded_output(%{"output" => output}) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> output
    end
  end

  defp decoded_output(response), do: response

  defp error_code(error) when is_map(error) do
    case Payload.get_any(error, ["code", :code]) do
      code when is_binary(code) and code != "" -> code
      _ -> "tool_failed"
    end
  end

  defp error_code(_error), do: "tool_failed"

  defp error_retryable(error) when is_map(error) do
    case Payload.get_any(error, ["retryable", :retryable]) do
      retryable when is_boolean(retryable) -> retryable
      _ -> false
    end
  end

  defp error_retryable(_error), do: false

  defp error_message(error, _output) when is_map(error) do
    case Payload.get_any(error, ["message", :message]) do
      message when is_binary(message) -> message
      _ -> nil
    end
  end

  defp error_message(_error, output) when is_binary(output), do: output
  defp error_message(_error, _output), do: nil

  defp error_reason(error) when is_map(error) do
    case Payload.get_any(error, ["reason", :reason]) do
      reason when is_binary(reason) -> reason
      reason when not is_nil(reason) -> inspect(reason)
      _ -> nil
    end
  end

  defp error_reason(_error), do: nil

  defp safe_arguments(arguments), do: Redaction.payload(arguments, 500)

  defp issue_identifier(opts) do
    case Keyword.get(opts, :issue) do
      %{identifier: identifier} when is_binary(identifier) -> identifier
      %{"identifier" => identifier} when is_binary(identifier) -> identifier
      _ -> Keyword.get(opts, :issue_identifier)
    end
  end

  defp issue_id(opts) do
    case Keyword.get(opts, :issue) do
      %{id: id} when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      _ -> Keyword.get(opts, :issue_id)
    end
  end

  defp record_event({:ok, recorder}, attrs, payload, tool, opts) do
    case recorder.(attrs, payload) do
      :ok -> :ok
      {:degraded, reason} -> audit_write_error(tool, payload, opts, reason)
      {:error, reason} -> audit_write_error(tool, payload, opts, reason)
    end
  end

  defp record_event(:error, _attrs, payload, tool, opts),
    do: audit_write_error(tool, payload, opts, :recorder_not_configured)

  defp audit_write_error(tool, payload, opts, reason) do
    result = {:error, {:linear_tool_audit_write_failed, reason}}

    Logger.error(
      "Linear tool audit recording failed action=continue_degraded tool=#{tool} task_id=#{inspect(Keyword.get(opts, :task_id))} issue_id=#{inspect(Map.get(payload, :issue_id))} issue_identifier=#{inspect(Map.get(payload, :issue_identifier))} session_id=#{inspect(Map.get(payload, :session_id))} run_id=#{inspect(Map.get(payload, :run_id))} outcome=#{inspect(result, limit: 20, printable_limit: 1_000)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}",
      event: "linear.tool_call.audit_failed",
      operation: "record_linear_tool_audit",
      location: "SymphonyElixir.Codex.LinearToolAudit.record_event/5",
      offending_value: %{tool: tool, reason: inspect(reason, limit: 20, printable_limit: 1_000)},
      expected_shape: ":ok from the configured audit recorder",
      error_code: "linear_tool_audit_write_failed",
      retryable: true,
      tool_call_id: Map.get(payload, :tool_call_id),
      issue_id: Map.get(payload, :issue_id),
      issue_identifier: Map.get(payload, :issue_identifier),
      session_id: Map.get(payload, :session_id),
      run_id: Map.get(payload, :run_id)
    )

    result
  end

  defp drop_nil_values(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end

defmodule SymphonyElixir.Codex.LinearToolAudit do
  @moduledoc """
  Structured audit events for Symphony-owned restricted Linear tools.
  """

  alias SymphonyElixir.{Payload, PersistenceProvider, Redaction}

  @linear_tools ~w(linear_task_read linear_task_update linear_issue_create)

  @spec linear_tool?(term()) :: boolean()
  def linear_tool?(tool) when tool in @linear_tools, do: true
  def linear_tool?(_tool), do: false

  @spec record(String.t(), term(), map(), keyword()) :: :ok
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
          arguments: safe_arguments(arguments),
          result: success_result(response),
          error: failure_error(response),
          started_at: started_at,
          duration_ms: duration_ms,
          message: message(tool, response)
        }
        |> drop_nil_values()

      PersistenceProvider.module().record_event(%{
        run_id: Keyword.get(opts, :run_id),
        issue_identifier: issue_identifier(opts),
        event_type: "linear.tool_call",
        payload: payload
      })
    end

    :ok
  rescue
    _error -> :ok
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

  defp failure_error(%{"success" => false} = response) do
    output = decoded_output(response)
    error = if is_map(output), do: Payload.get_any(output, ["error", :error]), else: nil

    %{
      class: failure_class(error, output),
      message: error_message(error, output),
      reason: error_reason(error)
    }
    |> drop_nil_values()
  end

  defp failure_error(_response), do: nil

  defp normalize_success_result(%{} = output) do
    output
    |> Map.take(["id", "identifier", "title", "url", "state", "issue_update", "comment_update", "reference_links", "requested_state", "issue", "workflow"])
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

  defp failure_class(error, output) when is_map(error) do
    message = error_message(error, output)
    reason = error_reason(error)

    cond do
      contains?(message, "Workflow profile is unavailable") -> "workflow_profile_unavailable"
      contains?(message, "not allowed") -> "issue_create_not_allowed"
      contains?(message, "requires non-empty") -> "validation_failed"
      contains?(message, "payload is too large") -> "payload_too_large"
      contains?(reason, "linear_graphql") -> "linear_graphql_error"
      contains?(reason, "context") -> "linear_context_unavailable"
      true -> "tool_failed"
    end
  end

  defp failure_class(_error, _output), do: "tool_failed"

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

  defp contains?(value, needle) when is_binary(value), do: String.contains?(value, needle)
  defp contains?(_value, _needle), do: false

  defp drop_nil_values(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end

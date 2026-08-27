defmodule SymphonyElixir.Codex.ToolRequestHandler do
  @moduledoc """
  Non-interactive policy for Codex app-server tool and approval requests.
  """

  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type action ::
          {:reply, map(), atom(), map()}
          | :approval_required
          | :input_required
          | :unhandled

  @spec handle(String.t(), map(), keyword()) :: action()
  def handle(method, payload, opts \\ []) when is_binary(method) and is_map(payload) do
    auto_approve_requests = Keyword.get(opts, :auto_approve_requests, false)
    tool_executor = Keyword.fetch!(opts, :tool_executor)

    maybe_handle_request(method, payload, tool_executor, auto_approve_requests)
  end

  @spec needs_input?(String.t(), map()) :: boolean()
  def needs_input?(method, payload)
      when is_binary(method) and is_map(payload) do
    mcp_elicitation_request?(method) ||
      (String.starts_with?(method, "turn/") && input_required_method?(method, payload))
  end

  def needs_input?(_method, _payload), do: false

  defp maybe_handle_request(
         "item/commandExecution/requestApproval",
         %{"id" => id},
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(id, "acceptForSession", auto_approve_requests)
  end

  defp maybe_handle_request(
         "item/tool/call",
         %{"id" => id, "params" => params},
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    {:reply, %{"id" => id, "result" => result}, event, %{}}
  end

  defp maybe_handle_request(
         "execCommandApproval",
         %{"id" => id},
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(id, "approved_for_session", auto_approve_requests)
  end

  defp maybe_handle_request(
         "applyPatchApproval",
         %{"id" => id},
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(id, "approved_for_session", auto_approve_requests)
  end

  defp maybe_handle_request(
         "item/fileChange/requestApproval",
         %{"id" => id},
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(id, "acceptForSession", auto_approve_requests)
  end

  defp maybe_handle_request(
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params},
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(id, params, auto_approve_requests)
  end

  defp maybe_handle_request(_method, _payload, _tool_executor, _auto_approve_requests), do: :unhandled

  defp approve_or_require(id, decision, true) do
    {:reply, %{"id" => id, "result" => %{"decision" => decision}}, :approval_auto_approved, %{decision: decision}}
  end

  defp approve_or_require(_id, _decision, false), do: :approval_required

  defp maybe_auto_answer_tool_request_user_input(id, params, true) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        {:reply, %{"id" => id, "result" => %{"answers" => answers}}, :approval_auto_approved, %{decision: decision}}

      :error ->
        reply_with_non_interactive_tool_input_answer(id, params)
    end
  end

  defp maybe_auto_answer_tool_request_user_input(id, params, false) do
    reply_with_non_interactive_tool_input_answer(id, params)
  end

  defp reply_with_non_interactive_tool_input_answer(id, params) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        result = %{"id" => id, "result" => %{"answers" => answers}}
        metadata = %{answer: @non_interactive_tool_input_answer}
        {:reply, result, :tool_input_auto_answered, metadata}

      :error ->
        :input_required
    end
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp tool_call_name(params) when is_map(params) do
    case SymphonyElixir.Payload.get_any(params, ["tool", :tool, "name", :name]) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    SymphonyElixir.Payload.get_any(params, ["arguments", :arguments], %{})
  end

  defp tool_call_arguments(_params), do: %{}

  defp mcp_elicitation_request?(method) when is_binary(method) do
    method in [
      "mcpServer/elicitation/request",
      "mcp/elicitation/request"
    ]
  end

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "requires_input") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end

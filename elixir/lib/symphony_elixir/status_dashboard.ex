defmodule SymphonyElixir.StatusDashboard do
  @moduledoc """
  Observes orchestrator status for Web dashboard updates.

  Terminal output is intentionally handled through normal Logger call sites in
  the runtime modules, not by rendering periodic status snapshots here.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.ObservabilityPubSub

  defstruct [
    :refresh_ms,
    :enabled,
    :render_interval_ms,
    :refresh_ms_override,
    :enabled_override,
    :render_interval_ms_override,
    :last_snapshot_fingerprint
  ]

  @type t :: %__MODULE__{
          refresh_ms: pos_integer(),
          enabled: boolean(),
          render_interval_ms: pos_integer(),
          refresh_ms_override: pos_integer() | nil,
          enabled_override: boolean() | nil,
          render_interval_ms_override: pos_integer() | nil,
          last_snapshot_fingerprint: term() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec notify_update(GenServer.name()) :: :ok
  def notify_update(server \\ __MODULE__) do
    ObservabilityPubSub.broadcast_update()

    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        send(pid, :refresh)
        :ok

      _ ->
        :ok
    end
  end

  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    refresh_ms_override = keyword_override(opts, :refresh_ms)
    enabled_override = keyword_override(opts, :enabled)
    render_interval_ms_override = keyword_override(opts, :render_interval_ms)
    observability = configured_observability()
    refresh_ms = refresh_ms_override || observability.refresh_ms
    render_interval_ms = render_interval_ms_override || observability.render_interval_ms
    enabled = resolve_override(enabled_override, observability.dashboard_enabled and dashboard_enabled?())
    schedule_tick(refresh_ms, enabled)

    {:ok,
     %__MODULE__{
       refresh_ms: refresh_ms,
       enabled: enabled,
       render_interval_ms: render_interval_ms,
       refresh_ms_override: refresh_ms_override,
       enabled_override: enabled_override,
       render_interval_ms_override: render_interval_ms_override,
       last_snapshot_fingerprint: nil
     }}
  end

  @spec render_offline_status() :: :ok
  def render_offline_status do
    Logger.error("Symphony application offline")
    :ok
  end

  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:tick, %{enabled: true} = state) do
    state = refresh_runtime_config(state)
    state = maybe_render(state)
    schedule_tick(state.refresh_ms, true)
    {:noreply, state}
  end

  def handle_info(:refresh, %{enabled: true} = state), do: {:noreply, maybe_render(refresh_runtime_config(state))}
  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info(:tick, state), do: {:noreply, state}

  defp refresh_runtime_config(%__MODULE__{} = state) do
    observability = configured_observability()

    %{
      state
      | enabled: resolve_override(state.enabled_override, observability.dashboard_enabled and dashboard_enabled?()),
        refresh_ms: state.refresh_ms_override || observability.refresh_ms,
        render_interval_ms: state.render_interval_ms_override || observability.render_interval_ms
    }
  end

  defp configured_observability do
    raw_observability = raw_observability_config()

    %{
      dashboard_enabled: raw_boolean(raw_observability, "dashboard_enabled", true),
      refresh_ms: raw_positive_integer(raw_observability, "refresh_ms", 1_000),
      render_interval_ms: raw_positive_integer(raw_observability, "render_interval_ms", 16)
    }
  end

  defp raw_observability_config do
    with {:ok, %{config: config}} <- Workflow.current(),
         observability when is_map(observability) <-
           Map.get(config, "observability") || Map.get(config, :observability) do
      observability
    else
      _ -> %{}
    end
  end

  defp raw_boolean(map, key, default) do
    case raw_value(map, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp raw_positive_integer(map, key, default) do
    case raw_value(map, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp raw_value(map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp schedule_tick(refresh_ms, true), do: Process.send_after(self(), :tick, refresh_ms)
  defp schedule_tick(_refresh_ms, false), do: :ok

  defp maybe_render(state) do
    snapshot_data = snapshot_payload()
    fingerprint = loggable_fingerprint(snapshot_data)

    state
    |> maybe_log_snapshot_unavailable(snapshot_data, fingerprint)
    |> maybe_update_snapshot_fingerprint(fingerprint)
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed refreshing status dashboard: #{Exception.message(error)}")
      state
  end

  defp maybe_log_snapshot_unavailable(state, :error, fingerprint)
       when fingerprint != state.last_snapshot_fingerprint do
    Logger.error("Orchestrator snapshot unavailable")
    state
  end

  defp maybe_log_snapshot_unavailable(state, _snapshot_data, _fingerprint), do: state

  defp maybe_update_snapshot_fingerprint(state, fingerprint) do
    if fingerprint == state.last_snapshot_fingerprint do
      state
    else
      Map.put(state, :last_snapshot_fingerprint, fingerprint)
    end
  end

  defp loggable_fingerprint({:ok, %{running: running, retrying: retrying, rate_limits: rate_limits}}) do
    %{
      running:
        Enum.map(running, fn running_entry ->
          %{
            identifier: running_entry.identifier,
            state: running_entry.state,
            session_id: running_entry.session_id,
            pid: running_entry.codex_app_server_pid,
            tokens: running_entry.codex_total_tokens,
            event: running_entry.last_codex_event,
            message: summarize_message(running_entry.last_codex_message)
          }
        end),
      retrying:
        Enum.map(retrying, fn retry ->
          %{
            identifier: retry.identifier,
            attempt: retry.attempt,
            due_in_ms: retry.due_in_ms,
            error: sanitize_retry_error(retry.error || "retry scheduled")
          }
        end),
      rate_limits: rate_limits
    }
  end

  defp loggable_fingerprint(:error), do: :snapshot_unavailable

  defp format_snapshot_content(_snapshot_data, _tps, _terminal_columns_override \\ nil), do: ""

  defp sanitize_retry_error(error) when is_binary(error) do
    error
    |> String.replace("\\r\\n", " ")
    |> String.replace("\\r", " ")
    |> String.replace("\\n", " ")
    |> String.replace("\r\n", " ")
    |> String.replace("\r", " ")
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_retry_error(_error), do: "retry scheduled"

  @doc false
  @spec format_snapshot_content_for_test(term(), number()) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps), do: format_snapshot_content(snapshot_data, tps)

  @doc false
  @spec format_snapshot_content_for_test(term(), number(), integer() | nil) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps, terminal_columns),
    do: format_snapshot_content(snapshot_data, tps, terminal_columns)

  defp snapshot_payload do
    if Process.whereis(Orchestrator) do
      case Orchestrator.snapshot() do
        %{
          running: running,
          retrying: retrying,
          codex_totals: codex_totals
        } = snapshot
        when is_list(running) and is_list(retrying) ->
          {:ok,
           %{
             running: running,
             retrying: retrying,
             codex_totals: codex_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling)
           }}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    unsigned
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> prepend(sign)
  end

  defp prepend("", value), do: value
  defp prepend(prefix, value), do: prefix <> value

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  @doc false
  @spec humanize_codex_message(term()) :: String.t()
  def humanize_codex_message(nil), do: "no codex message yet"

  def humanize_codex_message(%{event: event, message: message}) do
    payload = unwrap_codex_message_payload(message)

    (humanize_codex_event(event, message, payload) || humanize_codex_payload(payload))
    |> truncate(140)
  end

  def humanize_codex_message(%{message: message}) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> truncate(140)
  end

  def humanize_codex_message(message) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> truncate(140)
  end

  defp summarize_message(message), do: humanize_codex_message(message)

  defp humanize_codex_event(:session_started, _message, payload) do
    session_id = map_value(payload, ["session_id", :session_id])

    if is_binary(session_id) do
      "session started (#{session_id})"
    else
      "session started"
    end
  end

  defp humanize_codex_event(:turn_input_required, _message, payload) do
    case map_value(payload, ["method", :method]) do
      method when method in ["mcpServer/elicitation/request", "mcp/elicitation/request"] ->
        humanize_mcp_elicitation(payload)

      _ ->
        "turn blocked: waiting for user input"
    end
  end

  defp humanize_codex_event(:approval_auto_approved, message, payload) do
    method =
      map_value(payload, ["method", :method]) ||
        map_path(message, ["payload", "method"]) ||
        map_path(message, [:payload, :method])

    decision = map_value(message, ["decision", :decision])

    base =
      if is_binary(method) do
        "#{humanize_codex_method(method, payload)} (auto-approved)"
      else
        "approval request auto-approved"
      end

    if is_binary(decision), do: "#{base}: #{decision}", else: base
  end

  defp humanize_codex_event(:tool_input_auto_answered, message, payload) do
    answer = map_value(message, ["answer", :answer])

    base =
      case humanize_codex_method("item/tool/requestUserInput", payload) do
        nil -> "tool input auto-answered"
        text -> "#{text} (auto-answered)"
      end

    if is_binary(answer), do: "#{base}: #{inline_text(answer)}", else: base
  end

  defp humanize_codex_event(:tool_call_completed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call completed", payload)

  defp humanize_codex_event(:tool_call_failed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call failed", payload)

  defp humanize_codex_event(:unsupported_tool_call, _message, payload),
    do: humanize_dynamic_tool_event("unsupported dynamic tool call rejected", payload)

  defp humanize_codex_event(:turn_ended_with_error, message, _payload), do: "turn ended with error: #{format_reason(message)}"
  defp humanize_codex_event(:startup_failed, message, _payload), do: "startup failed: #{format_reason(message)}"
  defp humanize_codex_event(:turn_failed, _message, payload), do: humanize_codex_method("turn/failed", payload)
  defp humanize_codex_event(:turn_cancelled, _message, _payload), do: "turn cancelled"
  defp humanize_codex_event(:malformed, _message, _payload), do: "malformed JSON event from codex"
  defp humanize_codex_event(_event, _message, _payload), do: nil

  defp unwrap_codex_message_payload(%{} = message) do
    cond do
      is_binary(map_value(message, ["method", :method])) -> message
      is_binary(map_value(message, ["session_id", :session_id])) -> message
      is_binary(map_value(message, ["reason", :reason])) -> message
      true -> map_value(message, ["payload", :payload]) || message
    end
  end

  defp unwrap_codex_message_payload(message), do: message

  defp humanize_codex_payload(%{} = payload) do
    case map_value(payload, ["method", :method]) do
      method when is_binary(method) ->
        humanize_codex_method(method, payload)

      _ ->
        cond do
          is_binary(map_value(payload, ["session_id", :session_id])) ->
            "session started (#{map_value(payload, ["session_id", :session_id])})"

          match?(%{"error" => _}, payload) ->
            "error: #{format_error_value(Map.get(payload, "error"))}"

          true ->
            payload
            |> inspect(pretty: true, limit: 30)
            |> String.replace("\n", " ")
            |> sanitize_ansi_and_control_bytes()
            |> String.trim()
        end
    end
  end

  defp humanize_codex_payload(payload) when is_binary(payload) do
    payload
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp humanize_codex_payload(payload) do
    payload
    |> inspect(pretty: true, limit: 20)
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp sanitize_ansi_and_control_bytes(value) when is_binary(value) do
    value
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
  end

  defp humanize_codex_method("thread/started", payload) do
    thread_id = map_path(payload, ["params", "thread", "id"]) || map_path(payload, [:params, :thread, :id])

    if is_binary(thread_id) do
      "thread started (#{thread_id})"
    else
      "thread started"
    end
  end

  defp humanize_codex_method("turn/started", payload) do
    turn_id = map_path(payload, ["params", "turn", "id"]) || map_path(payload, [:params, :turn, :id])

    if is_binary(turn_id) do
      "turn started (#{turn_id})"
    else
      "turn started"
    end
  end

  defp humanize_codex_method("turn/completed", payload) do
    status =
      map_path(payload, ["params", "turn", "status"]) ||
        map_path(payload, [:params, :turn, :status]) ||
        "completed"

    usage =
      map_path(payload, ["params", "usage"]) ||
        map_path(payload, [:params, :usage]) ||
        map_path(payload, ["params", "tokenUsage"]) ||
        map_path(payload, [:params, :tokenUsage]) ||
        map_value(payload, ["usage", :usage])

    usage_suffix =
      case format_usage_counts(usage) do
        nil -> ""
        usage_text -> " (#{usage_text})"
      end

    "turn completed (#{status})#{usage_suffix}"
  end

  defp humanize_codex_method("turn/failed", payload) do
    error_message =
      map_path(payload, ["params", "error", "message"]) ||
        map_path(payload, [:params, :error, :message])

    if is_binary(error_message), do: "turn failed: #{error_message}", else: "turn failed"
  end

  defp humanize_codex_method("turn/cancelled", _payload), do: "turn cancelled"

  defp humanize_codex_method("turn/diff/updated", payload) do
    diff =
      map_path(payload, ["params", "diff"]) ||
        map_path(payload, [:params, :diff]) ||
        ""

    if is_binary(diff) and diff != "" do
      line_count = diff |> String.split("\n", trim: true) |> length()
      "turn diff updated (#{line_count} lines)"
    else
      "turn diff updated"
    end
  end

  defp humanize_codex_method("turn/plan/updated", payload) do
    plan_entries =
      map_path(payload, ["params", "plan"]) ||
        map_path(payload, [:params, :plan]) ||
        map_path(payload, ["params", "steps"]) ||
        map_path(payload, [:params, :steps]) ||
        map_path(payload, ["params", "items"]) ||
        map_path(payload, [:params, :items]) ||
        []

    if is_list(plan_entries) do
      "plan updated (#{length(plan_entries)} steps)"
    else
      "plan updated"
    end
  end

  defp humanize_codex_method("thread/tokenUsage/updated", payload) do
    usage =
      map_path(payload, ["params", "tokenUsage", "total"]) ||
        map_path(payload, [:params, :tokenUsage, :total]) ||
        map_value(payload, ["usage", :usage])

    case format_usage_counts(usage) do
      nil -> "thread token usage updated"
      usage_text -> "thread token usage updated (#{usage_text})"
    end
  end

  defp humanize_codex_method("item/started", payload), do: humanize_item_lifecycle("started", payload)
  defp humanize_codex_method("item/completed", payload), do: humanize_item_lifecycle("completed", payload)

  defp humanize_codex_method("item/agentMessage/delta", payload),
    do: humanize_streaming_event("agent message streaming", payload)

  defp humanize_codex_method("item/plan/delta", payload),
    do: humanize_streaming_event("plan streaming", payload)

  defp humanize_codex_method("item/reasoning/summaryTextDelta", payload),
    do: humanize_streaming_event("reasoning summary streaming", payload)

  defp humanize_codex_method("item/reasoning/summaryPartAdded", payload),
    do: humanize_streaming_event("reasoning summary section added", payload)

  defp humanize_codex_method("item/reasoning/textDelta", payload),
    do: humanize_streaming_event("reasoning text streaming", payload)

  defp humanize_codex_method("item/commandExecution/outputDelta", payload),
    do: humanize_streaming_event("command output streaming", payload)

  defp humanize_codex_method("item/fileChange/outputDelta", payload),
    do: humanize_streaming_event("file change output streaming", payload)

  defp humanize_codex_method("item/commandExecution/requestApproval", payload) do
    command = extract_command(payload)

    if is_binary(command) do
      "command approval requested (#{command})"
    else
      "command approval requested"
    end
  end

  defp humanize_codex_method("item/fileChange/requestApproval", payload) do
    change_count = map_path(payload, ["params", "fileChangeCount"]) || map_path(payload, ["params", "changeCount"])

    if is_integer(change_count) and change_count > 0 do
      "file change approval requested (#{change_count} files)"
    else
      "file change approval requested"
    end
  end

  defp humanize_codex_method("item/tool/requestUserInput", payload) do
    question =
      map_path(payload, ["params", "question"]) ||
        map_path(payload, ["params", "prompt"]) ||
        map_path(payload, [:params, :question]) ||
        map_path(payload, [:params, :prompt])

    if is_binary(question) and String.trim(question) != "" do
      "tool requires user input: #{inline_text(question)}"
    else
      "tool requires user input"
    end
  end

  defp humanize_codex_method("tool/requestUserInput", payload),
    do: humanize_codex_method("item/tool/requestUserInput", payload)

  defp humanize_codex_method("mcpServer/elicitation/request", payload), do: humanize_mcp_elicitation(payload)
  defp humanize_codex_method("mcp/elicitation/request", payload), do: humanize_mcp_elicitation(payload)

  defp humanize_codex_method("account/updated", payload) do
    auth_mode =
      map_path(payload, ["params", "authMode"]) ||
        map_path(payload, [:params, :authMode]) ||
        "unknown"

    "account updated (auth #{auth_mode})"
  end

  defp humanize_codex_method("account/rateLimits/updated", payload) do
    rate_limits =
      map_path(payload, ["params", "rateLimits"]) ||
        map_path(payload, [:params, :rateLimits])

    "rate limits updated: #{format_rate_limits_summary(rate_limits)}"
  end

  defp humanize_codex_method("account/chatgptAuthTokens/refresh", _payload), do: "account auth token refresh requested"

  defp humanize_codex_method("item/tool/call", payload) do
    tool = dynamic_tool_name(payload)

    if is_binary(tool) and String.trim(tool) != "" do
      "dynamic tool call requested (#{tool})"
    else
      "dynamic tool call requested"
    end
  end

  defp humanize_codex_method(<<"codex/event/", suffix::binary>>, payload) do
    humanize_codex_wrapper_event(suffix, payload)
  end

  defp humanize_codex_method(method, payload) do
    msg_type =
      map_path(payload, ["params", "msg", "type"]) ||
        map_path(payload, [:params, :msg, :type])

    if is_binary(msg_type) do
      "#{method} (#{msg_type})"
    else
      method
    end
  end

  defp humanize_mcp_elicitation(payload) do
    details =
      [
        {"server", extract_mcp_server_name(payload)},
        {"tool", extract_mcp_tool_name(payload)},
        {"prompt", extract_mcp_elicitation_prompt(payload)}
      ]
      |> Enum.flat_map(fn
        {_label, nil} -> []
        {label, value} -> ["#{label}: #{inline_text(value)}"]
      end)

    case details do
      [] -> "MCP elicitation requested"
      _ -> "MCP elicitation requested (#{Enum.join(details, ", ")})"
    end
  end

  defp extract_mcp_server_name(payload) do
    first_binary_path(payload, [
      ["params", "server"],
      [:params, :server],
      ["params", "serverName"],
      [:params, :serverName],
      ["params", "server_name"],
      [:params, :server_name],
      ["params", "mcpServer"],
      [:params, :mcpServer],
      ["params", "mcp_server"],
      [:params, :mcp_server],
      ["params", "server", "name"],
      [:params, :server, :name],
      ["params", "request", "server"],
      [:params, :request, :server],
      ["params", "request", "serverName"],
      [:params, :request, :serverName]
    ])
  end

  defp extract_mcp_tool_name(payload) do
    first_binary_path(payload, [
      ["params", "tool"],
      [:params, :tool],
      ["params", "toolName"],
      [:params, :toolName],
      ["params", "tool_name"],
      [:params, :tool_name],
      ["params", "name"],
      [:params, :name],
      ["params", "request", "tool"],
      [:params, :request, :tool],
      ["params", "request", "toolName"],
      [:params, :request, :toolName],
      ["params", "item", "tool"],
      [:params, :item, :tool],
      ["params", "item", "name"],
      [:params, :item, :name]
    ])
  end

  defp extract_mcp_elicitation_prompt(payload) do
    first_binary_path(payload, [
      ["params", "prompt"],
      [:params, :prompt],
      ["params", "message"],
      [:params, :message],
      ["params", "question"],
      [:params, :question],
      ["params", "request", "prompt"],
      [:params, :request, :prompt],
      ["params", "request", "message"],
      [:params, :request, :message],
      ["params", "elicitation", "prompt"],
      [:params, :elicitation, :prompt],
      ["params", "elicitation", "message"],
      [:params, :elicitation, :message]
    ])
  end

  defp first_binary_path(payload, paths) do
    Enum.find_value(paths, fn path ->
      payload
      |> map_path(path)
      |> non_blank_binary()
    end)
  end

  defp non_blank_binary(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_blank_binary(_value), do: nil

  defp humanize_dynamic_tool_event(base, payload) do
    case dynamic_tool_name(payload) do
      tool when is_binary(tool) ->
        trimmed = String.trim(tool)

        if trimmed == "" do
          base
        else
          "#{base} (#{trimmed})"
        end

      _ ->
        base
    end
  end

  defp dynamic_tool_name(payload) do
    map_path(payload, ["params", "tool"]) ||
      map_path(payload, ["params", "name"]) ||
      map_path(payload, [:params, :tool]) ||
      map_path(payload, [:params, :name])
  end

  defp humanize_item_lifecycle(state, payload) do
    item =
      map_path(payload, ["params", "item"]) ||
        map_path(payload, [:params, :item]) ||
        %{}

    item_type = item |> map_value(["type", :type]) |> humanize_item_type()
    item_status = map_value(item, ["status", :status])
    item_id = map_value(item, ["id", :id])

    details =
      []
      |> append_if_present(short_id(item_id))
      |> append_if_present(humanize_status(item_status))

    detail_suffix = if details == [], do: "", else: " (#{Enum.join(details, ", ")})"
    "item #{state}: #{item_type}#{detail_suffix}"
  end

  defp humanize_codex_wrapper_event("mcp_startup_update", payload) do
    server =
      map_path(payload, ["params", "msg", "server"]) ||
        map_path(payload, [:params, :msg, :server]) ||
        "mcp"

    state =
      map_path(payload, ["params", "msg", "status", "state"]) ||
        map_path(payload, [:params, :msg, :status, :state]) ||
        "updated"

    "mcp startup: #{server} #{state}"
  end

  defp humanize_codex_wrapper_event("mcp_startup_complete", _payload), do: "mcp startup complete"
  defp humanize_codex_wrapper_event("task_started", _payload), do: "task started"
  defp humanize_codex_wrapper_event("user_message", _payload), do: "user message received"

  defp humanize_codex_wrapper_event("item_started", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_codex_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item started (#{humanize_item_type(type)})"
      _ -> "item started"
    end
  end

  defp humanize_codex_wrapper_event("item_completed", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_codex_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item completed (#{humanize_item_type(type)})"
      _ -> "item completed"
    end
  end

  defp humanize_codex_wrapper_event("agent_message_delta", payload),
    do: humanize_streaming_event("agent message streaming", payload)

  defp humanize_codex_wrapper_event("agent_message_content_delta", payload),
    do: humanize_streaming_event("agent message content streaming", payload)

  defp humanize_codex_wrapper_event("agent_reasoning_delta", payload),
    do: humanize_streaming_event("reasoning streaming", payload)

  defp humanize_codex_wrapper_event("reasoning_content_delta", payload),
    do: humanize_streaming_event("reasoning content streaming", payload)

  defp humanize_codex_wrapper_event("agent_reasoning_section_break", _payload), do: "reasoning section break"
  defp humanize_codex_wrapper_event("agent_reasoning", payload), do: humanize_reasoning_update(payload)
  defp humanize_codex_wrapper_event("turn_diff", _payload), do: "turn diff updated"
  defp humanize_codex_wrapper_event("exec_command_begin", payload), do: humanize_exec_command_begin(payload)
  defp humanize_codex_wrapper_event("exec_command_end", payload), do: humanize_exec_command_end(payload)
  defp humanize_codex_wrapper_event("exec_command_output_delta", _payload), do: "command output streaming"
  defp humanize_codex_wrapper_event("mcp_tool_call_begin", _payload), do: "mcp tool call started"
  defp humanize_codex_wrapper_event("mcp_tool_call_end", _payload), do: "mcp tool call completed"

  defp humanize_codex_wrapper_event("token_count", payload) do
    usage = extract_first_path(payload, token_usage_paths())

    case format_usage_counts(usage) do
      nil -> "token count update"
      usage_text -> "token count update (#{usage_text})"
    end
  end

  defp humanize_codex_wrapper_event(other, payload) do
    msg_type =
      map_path(payload, ["params", "msg", "type"]) ||
        map_path(payload, [:params, :msg, :type])

    if is_binary(msg_type) do
      "#{other} (#{msg_type})"
    else
      other
    end
  end

  defp humanize_exec_command_begin(payload) do
    command =
      map_path(payload, ["params", "msg", "command"]) ||
        map_path(payload, [:params, :msg, :command]) ||
        map_path(payload, ["params", "msg", "parsed_cmd"]) ||
        map_path(payload, [:params, :msg, :parsed_cmd])

    command = normalize_command(command)

    if is_binary(command) do
      command
    else
      "command started"
    end
  end

  defp humanize_exec_command_end(payload) do
    exit_code =
      map_path(payload, ["params", "msg", "exit_code"]) ||
        map_path(payload, [:params, :msg, :exit_code]) ||
        map_path(payload, ["params", "msg", "exitCode"]) ||
        map_path(payload, [:params, :msg, :exitCode])

    if is_integer(exit_code) do
      "command completed (exit #{exit_code})"
    else
      "command completed"
    end
  end

  defp format_usage_counts(usage) when is_map(usage) do
    input =
      parse_integer(
        map_value(usage, [
          "input_tokens",
          :input_tokens,
          "prompt_tokens",
          :prompt_tokens,
          "inputTokens",
          :inputTokens,
          "promptTokens",
          :promptTokens
        ])
      )

    output =
      parse_integer(
        map_value(usage, [
          "output_tokens",
          :output_tokens,
          "completion_tokens",
          :completion_tokens,
          "outputTokens",
          :outputTokens,
          "completionTokens",
          :completionTokens
        ])
      )

    total =
      parse_integer(
        map_value(usage, [
          "total_tokens",
          :total_tokens,
          "total",
          :total,
          "totalTokens",
          :totalTokens
        ])
      )

    parts =
      []
      |> append_usage_part("in", input)
      |> append_usage_part("out", output)
      |> append_usage_part("total", total)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, ", ")
    end
  end

  defp format_usage_counts(_usage), do: nil

  defp append_usage_part(parts, _label, value) when not is_integer(value), do: parts
  defp append_usage_part(parts, label, value), do: parts ++ ["#{label} #{format_count(value)}"]

  defp format_rate_limits_summary(nil), do: "n/a"

  defp format_rate_limits_summary(rate_limits) when is_map(rate_limits) do
    primary = map_value(rate_limits, ["primary", :primary])
    secondary = map_value(rate_limits, ["secondary", :secondary])

    primary_text = format_rate_limit_bucket_summary(primary)
    secondary_text = format_rate_limit_bucket_summary(secondary)

    cond do
      primary_text != nil and secondary_text != nil -> "primary #{primary_text}; secondary #{secondary_text}"
      primary_text != nil -> "primary #{primary_text}"
      secondary_text != nil -> "secondary #{secondary_text}"
      true -> "n/a"
    end
  end

  defp format_rate_limits_summary(_rate_limits), do: "n/a"

  defp format_rate_limit_bucket_summary(bucket) when is_map(bucket) do
    used_percent = map_value(bucket, ["usedPercent", :usedPercent])
    window_mins = map_value(bucket, ["windowDurationMins", :windowDurationMins])

    cond do
      is_number(used_percent) and is_integer(window_mins) ->
        "#{used_percent}% / #{window_mins}m"

      is_number(used_percent) ->
        "#{used_percent}% used"

      true ->
        nil
    end
  end

  defp format_rate_limit_bucket_summary(_bucket), do: nil

  defp format_error_value(%{"message" => message}) when is_binary(message), do: message
  defp format_error_value(%{message: message}) when is_binary(message), do: message
  defp format_error_value(error), do: inspect(error, limit: 10)

  defp format_reason(message) when is_map(message) do
    case map_value(message, ["reason", :reason]) do
      nil ->
        message
        |> inspect(limit: 10)
        |> inline_text()

      reason ->
        format_error_value(reason)
    end
  end

  defp format_reason(other), do: format_error_value(other)

  defp humanize_streaming_event(label, payload) do
    case extract_delta_preview(payload) do
      nil -> label
      preview -> "#{label}: #{preview}"
    end
  end

  defp humanize_reasoning_update(payload) do
    case extract_reasoning_focus(payload) do
      nil -> "reasoning update"
      focus -> "reasoning update: #{focus}"
    end
  end

  defp extract_reasoning_focus(payload) do
    value = extract_first_path(payload, reasoning_focus_paths())

    if is_binary(value) do
      trimmed = String.trim(value)
      if trimmed == "", do: nil, else: inline_text(trimmed)
    else
      nil
    end
  end

  defp extract_delta_preview(payload) do
    delta = extract_first_path(payload, delta_paths())

    case delta do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: inline_text(trimmed)

      _ ->
        nil
    end
  end

  defp extract_command(payload) do
    payload
    |> map_path(["params", "parsedCmd"])
    |> fallback_command(payload)
    |> normalize_command()
  end

  defp fallback_command(nil, payload) do
    map_path(payload, ["params", "command"]) ||
      map_path(payload, ["params", "cmd"]) ||
      map_path(payload, ["params", "argv"]) ||
      map_path(payload, ["params", "args"])
  end

  defp fallback_command(command, _payload), do: command

  defp normalize_command(%{} = command) do
    binary_command = map_value(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = map_value(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command), do: inline_text(command)

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> inline_text()
    else
      nil
    end
  end

  defp normalize_command(_command), do: nil

  defp humanize_item_type(nil), do: "item"

  defp humanize_item_type(type) when is_binary(type) do
    type
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> String.replace("/", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_item_type(type), do: to_string(type)

  defp humanize_status(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_status(_status), do: nil

  defp short_id(id) when is_binary(id) and byte_size(id) > 12, do: String.slice(id, 0, 12)
  defp short_id(id) when is_binary(id), do: id
  defp short_id(_id), do: nil

  defp append_if_present(list, value) when is_binary(value) and value != "", do: list ++ [value]
  defp append_if_present(list, _value), do: list

  defp wrapper_payload_type(payload) do
    map_path(payload, ["params", "msg", "payload", "type"]) ||
      map_path(payload, [:params, :msg, :payload, :type])
  end

  defp inline_text(text) when is_binary(text) do
    text
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(80)
  end

  defp inline_text(other), do: other |> to_string() |> inline_text()

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp token_usage_paths do
    [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total]
    ]
  end

  defp delta_paths do
    [
      ["params", "delta"],
      [:params, :delta],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "msg", "textDelta"],
      [:params, :msg, :textDelta],
      ["params", "outputDelta"],
      [:params, :outputDelta],
      ["params", "msg", "outputDelta"],
      [:params, :msg, :outputDelta],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "textDelta"],
      [:params, :msg, :payload, :textDelta],
      ["params", "msg", "payload", "outputDelta"],
      [:params, :msg, :payload, :outputDelta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]
  end

  defp reasoning_focus_paths do
    [
      ["params", "reason"],
      [:params, :reason],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "summary"],
      [:params, :summary],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "reason"],
      [:params, :msg, :reason],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "summary"],
      [:params, :msg, :summary],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "payload", "reason"],
      [:params, :msg, :payload, :reason],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "summary"],
      [:params, :msg, :payload, :summary],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text]
    ]
  end

  defp extract_first_path(payload, paths) do
    Enum.find_value(paths, fn path ->
      map_path(payload, path)
    end)
  end

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_data, _path), do: nil

  defp fetch_map_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        alternate = alternate_key(key)

        if alternate == key do
          :error
        else
          Map.fetch(map, alternate)
        end
    end
  end

  defp alternate_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)
  defp alternate_key(key), do: key

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value

  defp dashboard_enabled? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() != :test
      rescue
        _ -> true
      end
    else
      true
    end
  end

  defp keyword_override(opts, key) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: nil
  end

  defp resolve_override(nil, default), do: default
  defp resolve_override(override, _default), do: override
end

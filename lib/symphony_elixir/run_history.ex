defmodule SymphonyElixir.RunHistory do
  @moduledoc """
  Presentation boundary for historical run session events.
  """

  alias SymphonyElixir.Codex.{MessageHumanizer, Protocol}
  alias SymphonyElixir.Codex.Protocol.Event
  alias SymphonyElixir.{Payload, RunSummary, StateName}

  @default_limit 100
  @max_payload_chars 800

  @type summary :: %{
          outcome: String.t(),
          final_message: String.t() | nil,
          last_codex_detail: String.t() | nil,
          actions: [String.t()],
          tools: [String.t()],
          commands: [String.t()],
          linear_updates: [String.t()],
          highlights: [String.t()],
          blockers: [String.t()],
          sessions: [String.t()],
          evidence_quality: :complete | :partial | :low_signal
        }

  @spec list_run_session_events(module(), String.t(), keyword()) :: [map()]
  def list_run_session_events(persistence, run_id, opts \\ [])
      when is_atom(persistence) and is_binary(run_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    persistence.list_events(run_id: run_id, limit: limit, order: :asc)
    |> Enum.map(&from_event/1)
    |> coalesce_rows()
  end

  @spec from_events([term()]) :: [map()]
  def from_events(events) when is_list(events) do
    events
    |> Enum.sort_by(&event_time_sort_key/1)
    |> Enum.map(&from_event/1)
    |> coalesce_rows()
  end

  @spec from_event(term()) :: map()
  def from_event(event) do
    type = event_type(event)
    payload = event_payload(event)
    protocol_event = protocol_event(type, payload)
    detail = detail(type, payload, protocol_event)

    %{
      at: event_time(event, protocol_event),
      event: type,
      label: label(type, payload),
      detail: detail,
      severity: severity(type, payload),
      source: source(type, payload),
      phase: payload_value(payload, ["phase", :phase]),
      operation:
        payload_value(payload, ["operation", :operation, "hook", :hook, "hook_name", :hook_name]) ||
          codex_operation(type, payload, protocol_event),
      low_signal: low_signal?(type, payload, detail),
      metadata: metadata(type, payload, protocol_event)
    }
  end

  @spec summarize(map() | nil, [map()]) :: summary()
  def summarize(run, history) when is_list(history) do
    RunSummary.summarize(run, history)
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(500)
  defp normalize_limit(_limit), do: @default_limit

  defp event_type(event), do: event |> value([:event_type, "event_type", :event, "event"]) |> to_string()

  defp event_payload(event) do
    case value(event, [:payload, "payload"]) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp event_time(event) do
    type = event_type(event)
    payload = event_payload(event)
    event_time(event, protocol_event(type, payload))
  end

  defp event_time(event, protocol_event) do
    protocol_timestamp(protocol_event) ||
      value(event, [:occurred_at, "occurred_at", :at, "at"])
  end

  defp event_time_sort_key(event) do
    case event_time(event) do
      %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp label("run.started", _payload), do: "Run started"
  defp label("run.completed", _payload), do: "Run completed"
  defp label("run.failed", _payload), do: "Run failed"
  defp label("run.stopped", _payload), do: "Run stopped"
  defp label("run.phase", payload), do: "Run phase #{payload_value(payload, ["status", :status]) || "updated"}"
  defp label("codex.update", payload), do: codex_update_label(payload)
  defp label("workspace.hook_output", payload), do: "Workspace #{payload_value(payload, ["hook", :hook, "hook_name", :hook_name]) || "hook"} output"
  defp label("workspace.hook_completed", payload), do: "Workspace #{payload_value(payload, ["hook", :hook, "hook_name", :hook_name]) || "hook"} completed"
  defp label("workspace.hook_failed", payload), do: "Workspace #{payload_value(payload, ["hook", :hook, "hook_name", :hook_name]) || "hook"} failed"
  defp label("linear.state_transition", _payload), do: "Linear state transition"
  defp label("linear.tool_call", payload), do: "Linear tool #{payload_value(payload, ["status", :status]) || "updated"}"

  defp label(type, payload) do
    payload_value(payload, ["label", :label]) ||
      type
      |> String.replace(".", " ")
      |> String.replace("_", " ")
      |> String.capitalize()
  end

  defp detail("run.phase", payload) do
    [payload_value(payload, ["phase", :phase]), payload_value(payload, ["status", :status])]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> fallback(payload_message(payload))
  end

  defp detail("linear.state_transition", payload) do
    from_state = payload_value(payload, ["from_state", :from_state])
    to_state = payload_value(payload, ["to_state", :to_state])

    if blank?(from_state) or blank?(to_state) do
      payload_message(payload)
    else
      "#{from_state} -> #{to_state}"
    end
  end

  defp detail("linear.tool_call", payload) do
    tool = payload_value(payload, ["tool", :tool]) || "Linear tool"
    status = payload_value(payload, ["status", :status])

    linear_tool_call_detail(status, tool, payload)
  end

  defp detail(type, payload) do
    payload_value(payload, ["detail", :detail]) ||
      payload_value(payload, ["output", :output, "recent_output", :recent_output]) ||
      payload_message(payload) ||
      type
  end

  defp detail("codex.update", payload, protocol_event),
    do: codex_update_detail(payload, protocol_event) || empty_codex_detail(payload) || "codex.update"

  defp detail(type, payload, _protocol_event), do: detail(type, payload)

  defp linear_tool_call_detail("success", tool, payload) do
    created = payload_value(payload, ["result", :result]) || %{}
    identifier = payload_value(created, ["identifier", :identifier])
    url = payload_value(created, ["url", :url])

    cond do
      is_binary(identifier) and is_binary(url) -> "#{tool} succeeded: #{identifier} #{url}"
      is_binary(identifier) -> "#{tool} succeeded: #{identifier}"
      true -> "#{tool} succeeded"
    end
  end

  defp linear_tool_call_detail("failure", tool, payload) do
    error = payload_value(payload, ["error", :error]) || %{}
    error_class = payload_value(error, ["class", :class]) || "tool_failed"
    message = payload_value(error, ["message", :message])

    if blank?(message), do: "#{tool} failed: #{error_class}", else: "#{tool} failed: #{error_class}: #{message}"
  end

  defp linear_tool_call_detail(_status, tool, payload), do: payload_message(payload) || "#{tool} updated"

  defp payload_message(payload) do
    case payload_value(payload, ["message", :message]) do
      nil -> nil
      message -> MessageHumanizer.humanize_codex_message(message)
    end
  end

  defp codex_update_label(payload) do
    case payload |> payload_value(["event", :event]) |> normalize_codex_event_name() do
      nil ->
        "Codex update"

      event_name ->
        "Codex " <> humanize_token(event_name)
    end
  end

  defp codex_update_detail(payload, %Event{} = protocol_event) do
    event = payload |> payload_value(["event", :event]) |> normalize_codex_event()

    case payload_value(payload, ["message", :message]) do
      nil ->
        nil

      _message ->
        codex_method_detail(protocol_event) ||
          protocol_event
          |> then(&MessageHumanizer.humanize_codex_message(%{event: event, message: &1}))
          |> append_response_error_context(protocol_event)
    end
  end

  defp codex_method_detail(%Event{} = event) do
    case event.method do
      "item/completed" -> completed_item_detail(event)
      "thread/tokenUsage/updated" -> token_usage_detail(event)
      "account/rateLimits/updated" -> rate_limit_detail(event)
      "turn/completed" -> turn_completed_detail(event)
      _ -> nil
    end
  end

  defp completed_item_detail(%Event{} = event) do
    text = normalize_text(event.item_text)

    cond do
      event.item_type == "agentMessage" and event.item_phase == "final_answer" and is_binary(text) ->
        "agent final answer: #{text}"

      event.item_type == "agentMessage" and is_binary(text) ->
        "agent message completed: #{text}"

      true ->
        nil
    end
  end

  defp token_usage_detail(%Event{} = event) do
    case token_usage_summary(event.usage) do
      nil -> nil
      summary -> "thread token usage updated (#{summary})"
    end
  end

  defp rate_limit_detail(%Event{} = event) do
    primary = rate_limit_bucket(event.rate_limits, "primary")
    secondary = rate_limit_bucket(event.rate_limits, "secondary")

    if primary || secondary do
      ["rate limits updated:", primary, secondary]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    end
  end

  defp turn_completed_detail(%Event{} = event) do
    suffix =
      if is_integer(event.turn_duration_ms) do
        " in #{format_duration_ms(event.turn_duration_ms)}"
      else
        ""
      end

    "turn completed (#{event.turn_status || "completed"})#{suffix}"
  end

  defp empty_codex_detail(payload) do
    if empty_codex_notification?(payload) do
      "Empty Codex notification; detailed payload was not persisted"
    end
  end

  defp empty_codex_notification?(payload) do
    payload |> payload_value(["event", :event]) |> normalize_codex_event_name() == "notification" and
      is_nil(payload_value(payload, ["message", :message]))
  end

  defp append_response_error_context(detail, %Event{} = event) do
    if is_binary(event.response_error_message) and !String.contains?(detail, event.response_error_message) do
      "#{detail}: #{event.response_error_message}"
    else
      detail
    end
  end

  defp normalize_codex_event(value) when is_atom(value), do: value

  defp normalize_codex_event(value) when is_binary(value) do
    Map.get(codex_event_atoms(), value, value)
  end

  defp normalize_codex_event(value), do: value

  defp codex_event_atoms do
    %{
      "session_started" => :session_started,
      "turn_input_required" => :turn_input_required,
      "approval_auto_approved" => :approval_auto_approved,
      "tool_input_auto_answered" => :tool_input_auto_answered,
      "tool_call_completed" => :tool_call_completed,
      "tool_call_failed" => :tool_call_failed,
      "unsupported_tool_call" => :unsupported_tool_call,
      "turn_ended_with_error" => :turn_ended_with_error,
      "startup_failed" => :startup_failed,
      "turn_failed" => :turn_failed,
      "turn_cancelled" => :turn_cancelled,
      "malformed" => :malformed
    }
  end

  defp normalize_codex_event_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_codex_event_name(value) when is_binary(value), do: value
  defp normalize_codex_event_name(_value), do: nil

  defp humanize_token(value) do
    value
    |> String.replace(".", " ")
    |> String.replace("_", " ")
  end

  defp fallback("", fallback), do: fallback || ""
  defp fallback(value, _fallback), do: value

  defp severity(type, payload) do
    cond do
      type in ["run.failed", "workspace.hook_failed"] -> :error
      type in ["run.stopped"] -> :warning
      type == "linear.tool_call" and payload_value(payload, ["status", :status]) == "failure" -> :error
      true -> payload_severity(payload)
    end
  end

  defp payload_severity(payload) do
    cond do
      codex_event(payload) in ["startup_failed", "turn_ended_with_error", "turn_failed"] -> :error
      codex_event(payload) in ["approval_required", "turn_input_required"] -> :warning
      payload_value(payload, ["status", :status]) in ["failed", "error"] -> :error
      payload_value(payload, ["severity", :severity]) in [:warning, "warning"] -> :warning
      payload_value(payload, ["severity", :severity]) in [:error, "error"] -> :error
      true -> :info
    end
  end

  defp source(type, payload) do
    payload_value(payload, ["source", :source]) ||
      cond do
        String.starts_with?(type, "linear.") -> :linear
        String.starts_with?(type, "workspace.") -> :system
        String.starts_with?(type, "run.") -> :system
        true -> :agent
      end
  end

  defp codex_event(payload), do: payload |> payload_value(["event", :event]) |> normalize_codex_event_name()

  defp bounded_payload(payload) when is_map(payload) do
    payload
    |> Enum.map(fn {key, value} -> {key, bound_value(value)} end)
    |> Map.new()
  end

  defp bound_value(value) when is_binary(value) do
    if String.length(value) > @max_payload_chars, do: String.slice(value, 0, @max_payload_chars) <> "...", else: value
  end

  defp bound_value(%Event{raw: raw}), do: bound_value(raw)
  defp bound_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp bound_value(value) when is_map(value), do: bounded_payload(value)
  defp bound_value(value) when is_list(value), do: Enum.map(value, &bound_value/1)
  defp bound_value(value), do: value

  defp metadata(type, payload, protocol_event) do
    payload
    |> bounded_payload()
    |> Map.merge(derived_metadata(type, payload, protocol_event))
  end

  defp derived_metadata("codex.update", payload, %Event{} = event) do
    session_id = payload_value(payload, ["session_id", :session_id]) || derived_session_id(event.thread_id, event.turn_id)

    %{}
    |> put_present("method", event.method)
    |> put_present("thread_id", event.thread_id)
    |> put_present("turn_id", event.turn_id)
    |> put_present("session_id", session_id)
    |> put_present("item_id", event.item_id)
  end

  defp derived_metadata(_type, _payload, _protocol_event), do: %{}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp derived_session_id(thread_id, turn_id) when is_binary(thread_id) and is_binary(turn_id), do: "#{thread_id}-#{turn_id}"
  defp derived_session_id(thread_id, _turn_id) when is_binary(thread_id), do: thread_id
  defp derived_session_id(_thread_id, _turn_id), do: nil

  defp protocol_timestamp(%Event{} = event) do
    cond do
      is_integer(event.timestamp_ms) -> DateTime.from_unix!(event.timestamp_ms, :millisecond)
      is_integer(event.timestamp_seconds) -> DateTime.from_unix!(event.timestamp_seconds, :second)
      true -> nil
    end
  rescue
    _error -> nil
  end

  defp protocol_timestamp(_protocol_event), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> then(fn text -> if text == "", do: nil, else: text end)
  end

  defp normalize_text(_value), do: nil

  defp token_usage_summary(usage) when is_map(usage) do
    total = Payload.get_any(usage, ["totalTokens", :totalTokens, "total_tokens", :total_tokens])
    input = Payload.get_any(usage, ["inputTokens", :inputTokens, "input_tokens", :input_tokens])
    output = Payload.get_any(usage, ["outputTokens", :outputTokens, "output_tokens", :output_tokens])

    parts =
      []
      |> append_count("total", total)
      |> append_count("in", input)
      |> append_count("out", output)

    if parts == [], do: nil, else: Enum.join(parts, ", ")
  end

  defp token_usage_summary(_usage), do: nil

  defp append_count(parts, _label, value) when not is_integer(value), do: parts
  defp append_count(parts, label, value), do: parts ++ ["#{label} #{format_integer(value)}"]

  defp rate_limit_bucket(rate_limits, key) when is_map(rate_limits) do
    bucket = Payload.get_any(rate_limits, rate_limit_bucket_keys(key))
    used = Payload.get_any(bucket || %{}, ["usedPercent", :usedPercent, "used_percent", :used_percent])
    duration = Payload.get_any(bucket || %{}, ["windowDurationMins", :windowDurationMins, "window_duration_mins", :window_duration_mins])

    if is_integer(used) and is_integer(duration) do
      "#{window_label(duration)} #{used}% / #{duration}m"
    end
  end

  defp rate_limit_bucket(_rate_limits, _key), do: nil

  defp rate_limit_bucket_keys("primary"), do: ["primary", :primary]
  defp rate_limit_bucket_keys("secondary"), do: ["secondary", :secondary]
  defp rate_limit_bucket_keys(key), do: [key]

  defp window_label(300), do: "primary"
  defp window_label(10_080), do: "secondary"
  defp window_label(_duration), do: "window"

  defp format_duration_ms(ms) when ms >= 60_000 do
    "#{Float.round(ms / 60_000, 1)}m"
  end

  defp format_duration_ms(ms), do: "#{ms}ms"

  defp format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp payload_value(payload, keys), do: Payload.get_any(payload, keys)

  defp value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp value(_map, _keys), do: nil

  defp blank?(value), do: StateName.blank_string?(value) or (not is_binary(value) and SymphonyElixir.Text.blankish?(value))

  defp codex_operation("codex.update", payload, %Event{} = event) do
    event.method ||
      event.tool ||
      payload_value(payload, ["event", :event])
  end

  defp codex_operation(_type, _payload, _protocol_event), do: nil

  defp protocol_event("codex.update", payload) do
    case payload_value(payload, ["message", :message]) do
      %Event{} = event -> event
      _message -> Protocol.normalize_event(payload)
    end
  end

  defp protocol_event(_type, _payload), do: nil

  defp low_signal?("codex.update", payload, _detail), do: empty_codex_notification?(payload)
  defp low_signal?(_type, _payload, _detail), do: false

  defp coalesce_rows(rows) do
    rows
    |> Enum.reduce([], &coalesce_row/2)
    |> Enum.reverse()
  end

  defp coalesce_row(row, [previous | rest]) do
    cond do
      coalescible_streaming_rows?(previous, row) -> [merge_streaming_rows(previous, row) | rest]
      coalescible_low_signal_rows?(previous, row) -> [merge_low_signal_rows(previous, row) | rest]
      true -> [row, previous | rest]
    end
  end

  defp coalesce_row(row, []), do: [row]

  defp coalescible_streaming_rows?(left, right) do
    left.event == right.event and
      left.label == right.label and
      left.source == right.source and
      left.operation == right.operation and
      streaming_agent_detail?(left.detail) and
      streaming_agent_detail?(right.detail)
  end

  defp streaming_agent_detail?(detail) when is_binary(detail) do
    String.contains?(detail, "agent message") and String.contains?(detail, ":")
  end

  defp streaming_agent_detail?(_detail), do: false

  defp merge_streaming_rows(left, right) do
    count = Map.get(left.metadata, "_coalesced_count", 1) + 1

    %{
      left
      | at: right.at || left.at,
        detail: merge_streaming_detail(left.detail, right.detail),
        metadata: Map.put(left.metadata, "_coalesced_count", count)
    }
  end

  defp merge_streaming_detail(left, right) do
    left_fragment = stream_fragment(left)
    right_fragment = stream_fragment(right)

    ["agent message streaming:", [left_fragment, right_fragment] |> Enum.reject(&blank?/1) |> Enum.join(" ")]
    |> Enum.join(" ")
    |> String.slice(0, 400)
  end

  defp stream_fragment(detail) when is_binary(detail) do
    detail
    |> String.replace_prefix("agent message streaming:", "")
    |> String.replace_prefix("agent message content streaming:", "")
    |> String.trim_leading()
  end

  defp stream_fragment(_detail), do: ""

  defp coalescible_low_signal_rows?(left, right) do
    Map.get(left, :low_signal, false) and
      Map.get(right, :low_signal, false) and
      left.event == right.event and
      left.label == right.label
  end

  defp merge_low_signal_rows(left, right) do
    count = Map.get(left.metadata, "_coalesced_count", 1) + 1

    %{
      left
      | at: right.at || left.at,
        detail: "#{count} empty Codex notifications; detailed payload was not persisted",
        metadata: Map.put(left.metadata, "_coalesced_count", count)
    }
  end
end

defmodule SymphonyElixir.RunHistory do
  @moduledoc """
  Presentation boundary for historical run session events.
  """

  alias SymphonyElixir.Codex.MessageHumanizer
  alias SymphonyElixir.{Payload, StateName}

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
    detail = detail(type, payload)

    %{
      at: event_time(event),
      event: type,
      label: label(type, payload),
      detail: detail,
      severity: severity(type, payload),
      source: source(type, payload),
      phase: payload_value(payload, ["phase", :phase]),
      operation:
        payload_value(payload, ["operation", :operation, "hook", :hook, "hook_name", :hook_name]) ||
          codex_operation(type, payload),
      low_signal: low_signal?(type, payload, detail),
      metadata: bounded_payload(payload)
    }
  end

  @spec summarize(map() | nil, [map()]) :: summary()
  def summarize(run, history) when is_list(history) do
    useful = Enum.reject(history, &Map.get(&1, :low_signal, false))

    %{
      outcome: run_outcome(run),
      final_message: final_agent_message(useful),
      last_codex_detail: last_codex_detail(useful),
      actions: actions(useful),
      tools: tool_summaries(useful),
      commands: command_summaries(useful),
      linear_updates: linear_updates(useful),
      highlights: useful |> Enum.filter(&highlight?/1) |> Enum.map(& &1.detail) |> Enum.uniq() |> Enum.take(5),
      blockers: blockers(run, useful),
      sessions: session_ids(history),
      evidence_quality: evidence_quality(useful)
    }
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(500)
  defp normalize_limit(_limit), do: @default_limit

  defp event_type(event), do: event |> value([:event_type, "event_type", :event, "event"]) |> to_string()
  defp event_payload(event), do: value(event, [:payload, "payload"]) || %{}
  defp event_time(event), do: value(event, [:occurred_at, "occurred_at", :at, "at"])

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

  defp detail("codex.update", payload), do: codex_update_detail(payload) || empty_codex_detail(payload) || "codex.update"

  defp detail(type, payload) do
    payload_value(payload, ["detail", :detail]) ||
      payload_value(payload, ["output", :output, "recent_output", :recent_output]) ||
      payload_message(payload) ||
      type
  end

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

  defp codex_update_detail(payload) do
    event = payload |> payload_value(["event", :event]) |> normalize_codex_event()

    case payload_value(payload, ["message", :message]) do
      nil ->
        nil

      message ->
        message
        |> then(&MessageHumanizer.humanize_codex_message(%{event: event, message: &1}))
        |> append_response_error_context(message)
    end
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

  defp append_response_error_context(detail, message) do
    response_message =
      Payload.get_path(message, [:response_error, "message"]) ||
        Payload.get_path(message, ["response_error", "message"])

    if is_binary(response_message) and !String.contains?(detail, response_message) do
      "#{detail}: #{response_message}"
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

  defp bounded_payload(_payload), do: %{}

  defp bound_value(value) when is_binary(value) do
    if String.length(value) > @max_payload_chars, do: String.slice(value, 0, @max_payload_chars) <> "...", else: value
  end

  defp bound_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp bound_value(value) when is_map(value), do: bounded_payload(value)
  defp bound_value(value) when is_list(value), do: Enum.map(value, &bound_value/1)
  defp bound_value(value), do: value

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

  defp codex_operation("codex.update", payload) do
    message = payload_value(payload, ["message", :message])

    Payload.get_any(message || %{}, ["method", :method]) ||
      Payload.get_path(message || %{}, ["params", "tool"]) ||
      Payload.get_path(message || %{}, [:params, :tool]) ||
      payload_value(payload, ["event", :event])
  end

  defp codex_operation(_type, _payload), do: nil

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

  defp run_outcome(nil), do: "n/a"
  defp run_outcome(run), do: "#{Map.get(run, :status, "unknown")} attempt #{Map.get(run, :attempt, "n/a")}"

  defp last_codex_detail(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn row ->
      if row.source == :agent and is_binary(row.detail) and row.detail not in ["", "codex.update"], do: row.detail
    end)
  end

  defp final_agent_message(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn row ->
      detail = to_string(row.detail || "")

      cond do
        String.starts_with?(detail, "agent message streaming:") ->
          detail |> String.replace_prefix("agent message streaming:", "") |> String.trim()

        String.starts_with?(detail, "agent message content streaming:") ->
          detail |> String.replace_prefix("agent message content streaming:", "") |> String.trim()

        true ->
          nil
      end
    end)
  end

  defp actions(history) do
    history
    |> Enum.map(&action_summary/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp action_summary(%{detail: detail}) when is_binary(detail) do
    cond do
      String.contains?(detail, "dynamic tool call requested") -> detail
      String.contains?(detail, "dynamic tool call completed") -> detail
      String.contains?(detail, "command completed") -> detail
      String.contains?(detail, "turn completed") -> detail
      String.contains?(detail, "session started") -> detail
      true -> nil
    end
  end

  defp action_summary(_row), do: nil

  defp tool_summaries(history) do
    history
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.map(fn {tool, count} -> "#{tool} x#{count}" end)
    |> Enum.sort()
    |> Enum.take(6)
  end

  defp tool_name(%{detail: detail}) when is_binary(detail) do
    case Regex.run(~r/dynamic tool call (?:requested|completed|failed|rejected) \(([^)]+)\)/, detail) do
      [_match, tool] -> tool
      _ -> nil
    end
  end

  defp tool_name(_row), do: nil

  defp command_summaries(history) do
    history
    |> Enum.map(&command_summary/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp command_summary(%{label: label, detail: detail}) when is_binary(detail) do
    cond do
      String.contains?(to_string(label), "Command") -> detail
      String.starts_with?(detail, "command completed") -> detail
      Regex.match?(~r/^(git|mix|mise|npm|pnpm|yarn|cargo|go|python|ruby|node)\b/, detail) -> detail
      true -> nil
    end
  end

  defp command_summary(_row), do: nil

  defp linear_updates(history) do
    history
    |> Enum.filter(&(&1.source == :linear or String.starts_with?(to_string(&1.event), "linear.")))
    |> Enum.map(& &1.detail)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp evidence_quality(history) do
    cond do
      final_agent_message(history) -> :complete
      Enum.any?(history, &highlight?/1) -> :partial
      true -> :low_signal
    end
  end

  defp highlight?(row) do
    detail = to_string(row.detail || "")
    String.contains?(detail, ["tool", "command", "session completed", "turn completed", "agent message"])
  end

  defp blockers(run, history) do
    run_failure =
      case run && Map.get(run, :failure_reason) do
        reason when is_binary(reason) and reason != "" -> [reason]
        _ -> []
      end

    history_failures =
      history
      |> Enum.filter(&(&1.severity in [:warning, :error]))
      |> Enum.map(& &1.detail)
      |> Enum.reject(&blank?/1)

    (run_failure ++ history_failures)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp session_ids(history) do
    history
    |> Enum.map(fn row -> Payload.get_any(row.metadata, ["session_id", :session_id]) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end
end

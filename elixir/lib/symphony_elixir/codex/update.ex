defmodule SymphonyElixir.Codex.Update do
  @moduledoc """
  Normalizes Codex app-server updates into run metadata, history, and persisted payloads.
  """

  alias SymphonyElixir.{Payload, Redaction, StatusDashboard}

  @default_history_limit 100

  @spec integrate(map(), map(), keyword()) :: {map(), map()}
  def integrate(running_entry, %{event: event, timestamp: timestamp} = update, opts \\ []) when is_map(running_entry) do
    history_limit = Keyword.get(opts, :history_limit, @default_history_limit)
    token_delta = token_delta(running_entry, update)
    turn_count = Map.get(running_entry, :turn_count, 0)

    updated_entry =
      running_entry
      |> Map.merge(%{
        last_codex_timestamp: timestamp,
        last_codex_message: summary(update),
        session_id: session_id_for_update(Map.get(running_entry, :session_id), update),
        last_codex_event: event,
        codex_app_server_pid: app_server_pid_for_update(Map.get(running_entry, :codex_app_server_pid), update),
        codex_input_tokens: Map.get(running_entry, :codex_input_tokens, 0) + token_delta.input_tokens,
        codex_output_tokens: Map.get(running_entry, :codex_output_tokens, 0) + token_delta.output_tokens,
        codex_total_tokens: Map.get(running_entry, :codex_total_tokens, 0) + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(Map.get(running_entry, :codex_last_reported_input_tokens, 0), token_delta.input_reported),
        codex_last_reported_output_tokens: max(Map.get(running_entry, :codex_last_reported_output_tokens, 0), token_delta.output_reported),
        codex_last_reported_total_tokens: max(Map.get(running_entry, :codex_last_reported_total_tokens, 0), token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, Map.get(running_entry, :session_id), update)
      })
      |> append_history(update, history_limit)

    {updated_entry, token_delta}
  end

  @spec summary(map()) :: map()
  def summary(update) do
    %{
      event: Map.get(update, :event),
      message: Map.get(update, :payload) || Map.get(update, :raw),
      timestamp: Map.get(update, :timestamp)
    }
  end

  @spec event_payload(map()) :: map()
  def event_payload(update) do
    %{
      event: Map.get(update, :event),
      message: Map.get(update, :message) || Map.get(update, :payload) || Map.get(update, :raw),
      timestamp: Map.get(update, :timestamp),
      session_id: Map.get(update, :session_id),
      debug: %{
        payload: Map.get(update, :payload),
        raw: Map.get(update, :raw)
      }
    }
    |> drop_blank_debug()
    |> scrub_persisted_payload()
  end

  @spec token_delta(map(), map()) :: map()
  def token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = token_usage(update)

    input = compute_token_delta(running_entry, :input, usage, :codex_last_reported_input_tokens)
    output = compute_token_delta(running_entry, :output, usage, :codex_last_reported_output_tokens)
    total = compute_token_delta(running_entry, :total, usage, :codex_last_reported_total_tokens)

    %{
      input_tokens: input.delta,
      output_tokens: output.delta,
      total_tokens: total.delta,
      input_reported: input.reported,
      output_reported: output.reported,
      total_reported: total.reported
    }
  end

  @spec rate_limits(map()) :: map() | nil
  def rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  @spec rate_limit_update_event?(map()) :: boolean()
  def rate_limit_update_event?(update) when is_map(update) do
    method =
      update
      |> Map.get(:payload)
      |> payload_method()

    method == "account/rateLimits/updated"
  end

  def rate_limit_update_event?(_update), do: false

  defp app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_binary(pid), do: pid
  defp app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_integer(pid), do: Integer.to_string(pid)
  defp app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid), do: to_string(pid)
  defp app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id), do: session_id
  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{event: :session_started, session_id: session_id})
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id, do: existing_count, else: existing_count + 1
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update) when is_integer(existing_count), do: existing_count
  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp append_history(running_entry, %{event: :notification} = update, history_limit) do
    metadata = history_metadata(update)

    case streaming_agent_message_fragment(update) do
      {:ok, fragment, key} ->
        append_streaming_history(running_entry, fragment, key, metadata, history_limit)

      :error ->
        append_session_history(running_entry, :notification, history_label(:notification), metadata, history_limit)
    end
  end

  defp append_history(running_entry, %{event: event} = update, history_limit) do
    append_session_history(running_entry, event, history_label(event), history_metadata(update), history_limit)
  end

  defp history_metadata(update), do: %{session_id: Map.get(update, :session_id), message: summary(update)}

  defp append_streaming_history(running_entry, fragment, coalescing_key, metadata, history_limit) do
    history = Map.get(running_entry, :session_history, [])
    total_count = Map.get(running_entry, :session_history_total_count, length(history)) + 1

    case history do
      [] ->
        running_entry
        |> Map.put(:session_history, [streaming_event(fragment, coalescing_key, metadata)])
        |> Map.put(:session_history_total_count, total_count)

      _ ->
        {last, rest_reversed} = pop_last_history_event(history)

        next_history =
          if coalescible_streaming_event?(last, coalescing_key) do
            Enum.reverse(rest_reversed) ++ [coalesce_streaming_event(last, fragment, metadata)]
          else
            history ++ [streaming_event(fragment, coalescing_key, metadata)]
          end

        running_entry
        |> Map.put(:session_history, Enum.take(next_history, -history_limit))
        |> Map.put(:session_history_total_count, total_count)
    end
  end

  defp append_session_history(running_entry, event, label, metadata, history_limit) do
    history = Map.get(running_entry, :session_history, [])
    next = session_history_event(event, label, metadata)

    running_entry
    |> Map.put(:session_history, Enum.take(history ++ [next], -history_limit))
    |> Map.put(:session_history_total_count, Map.get(running_entry, :session_history_total_count, length(history)) + 1)
  end

  defp pop_last_history_event(history) do
    [last | rest_reversed] = Enum.reverse(history)
    {last, rest_reversed}
  end

  defp streaming_event(fragment, coalescing_key, metadata) do
    metadata =
      metadata
      |> Map.put(:coalescing_key, coalescing_key)
      |> Map.put(:coalesced_event_count, 1)
      |> Map.put(:coalesced_text, fragment)
      |> Map.put(:coalesced_last_at, DateTime.utc_now())

    session_history_event(:notification, history_label(:notification), metadata)
    |> Map.put(:detail, streaming_detail(fragment, 1))
  end

  defp coalescible_streaming_event?(%{event: :notification, metadata: metadata}, coalescing_key) when is_map(metadata),
    do: Map.get(metadata, :coalescing_key) == coalescing_key

  defp coalescible_streaming_event?(_event, _coalescing_key), do: false

  defp coalesce_streaming_event(last, fragment, metadata) do
    existing_metadata = Map.get(last, :metadata, %{})
    text = smart_join_fragment(Map.get(existing_metadata, :coalesced_text, ""), fragment)
    count = Map.get(existing_metadata, :coalesced_event_count, 1) + 1

    merged_metadata =
      existing_metadata
      |> Map.merge(metadata)
      |> Map.put(:coalesced_event_count, count)
      |> Map.put(:coalesced_text, text)
      |> Map.put(:coalesced_last_at, DateTime.utc_now())

    last
    |> Map.put(:detail, streaming_detail(text, count))
    |> Map.put(:metadata, sanitize_history_metadata(merged_metadata))
  end

  defp streaming_detail(text, 1), do: "agent message streaming: #{text}"
  defp streaming_detail(text, count), do: "agent message streaming: #{text} (#{count} fragments)"

  defp streaming_agent_message_fragment(%{payload: payload} = update) when is_map(payload) do
    method = Payload.get_any(payload, ["method", :method])

    if method in ["item/agentMessage/delta", "codex/event/agent_message_delta", "codex/event/agent_message_content_delta"] do
      case extract_streaming_delta(payload) do
        fragment when is_binary(fragment) and fragment != "" -> {:ok, fragment, streaming_key(update, payload, method)}
        _ -> :error
      end
    else
      :error
    end
  end

  defp streaming_agent_message_fragment(_update), do: :error

  defp streaming_key(update, payload, method) do
    item_id =
      Payload.get_path(payload, ["params", "id"]) ||
        Payload.get_path(payload, [:params, :id]) ||
        Payload.get_path(payload, ["params", "itemId"]) ||
        Payload.get_path(payload, [:params, :itemId]) ||
        Payload.get_path(payload, ["params", "msg", "id"]) ||
        Payload.get_path(payload, [:params, :msg, :id])

    [Map.get(update, :session_id), method, item_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp extract_streaming_delta(payload) do
    [
      ["params", "delta"],
      [:params, :delta],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]
    |> Enum.find_value(fn path -> payload |> Payload.get_path(path) |> normalize_delta() end)
  end

  defp normalize_delta(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_delta(_value), do: nil

  defp smart_join_fragment("", fragment), do: fragment

  defp smart_join_fragment(text, fragment) do
    cond do
      String.starts_with?(fragment, [" ", "\n", "\t"]) -> text <> fragment
      String.starts_with?(fragment, [".", ",", ":", ";", "?", "!", ")", "]", "}", "'", "\"", "’"]) -> text <> fragment
      String.ends_with?(text, ["(", "[", "{", "\"", "'", "“"]) -> text <> fragment
      true -> text <> " " <> fragment
    end
  end

  defp session_history_event(event, label, metadata) do
    %{
      at: DateTime.utc_now(),
      event: event,
      label: label,
      detail: history_detail(event, metadata),
      severity: history_severity(event, metadata),
      source: history_source(event, metadata),
      metadata: sanitize_history_metadata(metadata)
    }
  end

  defp history_label(event), do: event |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp history_detail(_event, %{message: message}), do: StatusDashboard.humanize_codex_message(message)
  defp history_detail(event, _metadata), do: to_string(event)
  defp history_source(_event, _metadata), do: :agent
  defp history_severity(event, _metadata) when event in [:startup_failed, :turn_ended_with_error, :turn_failed], do: :error
  defp history_severity(event, _metadata) when event in [:approval_required, :turn_input_required], do: :warning
  defp history_severity(_event, _metadata), do: :info

  defp sanitize_history_metadata(metadata) when is_map(metadata), do: metadata |> Enum.map(fn {key, value} -> {key, sanitize_history_value(value)} end) |> Map.new()
  defp sanitize_history_value(value) when is_binary(value), do: if(String.length(value) > 500, do: String.slice(value, 0, 500) <> "...", else: value)
  defp sanitize_history_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_history_value(value) when is_map(value), do: sanitize_history_metadata(value)
  defp sanitize_history_value(value) when is_list(value), do: Enum.map(value, &sanitize_history_value/1)
  defp sanitize_history_value(value), do: value

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)
    delta = if is_integer(next_total) and next_total >= prev_reported, do: next_total - prev_reported, else: 0
    %{delta: max(delta, 0), reported: if(is_integer(next_total), do: next_total, else: prev_reported)}
  end

  defp token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    explicit_map_at_paths(payload, [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ])
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Payload.get_any(payload, ["method", :method])

    direct =
      Payload.get_any(payload, ["usage", :usage]) ||
        Payload.get_path(payload, ["params", "usage"]) ||
        Payload.get_path(payload, [:params, :usage])

    if method in ["turn/completed", :turn_completed] and is_map(direct) and integer_token_map?(direct), do: direct
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp payload_method(payload) when is_map(payload) do
    Payload.get_any(payload, ["method", :method]) ||
      Payload.get_path(payload, ["params", "method"]) ||
      Payload.get_path(payload, [:params, :method])
  end

  defp payload_method(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Payload.get_any(payload, ["rate_limits", :rate_limits])

    cond do
      rate_limits_map?(direct) -> direct
      rate_limits_map?(payload) -> payload
      true -> rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload), do: rate_limit_payloads(payload)
  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload), do: payload |> Map.values() |> find_rate_limits()
  defp rate_limit_payloads(payload) when is_list(payload), do: find_rate_limits(payload)

  defp find_rate_limits(values) do
    Enum.reduce_while(values, nil, fn value, _acc ->
      case rate_limits_from_payload(value) do
        nil -> {:cont, nil}
        rate_limits -> {:halt, rate_limits}
      end
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id = Payload.get_any(payload, ["limit_id", :limit_id, "limit_name", :limit_name])
    has_buckets = Enum.any?(["primary", :primary, "secondary", :secondary, "credits", :credits], &Map.has_key?(payload, &1))
    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths),
    do:
      Enum.find_value(paths, fn path ->
        value = Payload.get_path(payload, path)
        if is_map(value) and integer_token_map?(value), do: value
      end)

  defp integer_token_map?(payload) do
    [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input) do
    payload_get(usage, [
      "input_tokens",
      "prompt_tokens",
      :input_tokens,
      :prompt_tokens,
      :input,
      "promptTokens",
      :promptTokens,
      "inputTokens",
      :inputTokens
    ])
  end

  defp get_token_usage(usage, :output) do
    payload_get(usage, [
      "output_tokens",
      "completion_tokens",
      :output_tokens,
      :completion_tokens,
      :output,
      :completion,
      "outputTokens",
      :outputTokens,
      "completionTokens",
      :completionTokens
    ])
  end

  defp get_token_usage(usage, :total) do
    payload_get(usage, ["total_tokens", "total", :total_tokens, :total, "totalTokens", :totalTokens])
  end

  defp payload_get(payload, fields) when is_list(fields), do: Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  defp payload_get(payload, field), do: map_integer_value(payload, field)
  defp map_integer_value(payload, field) when is_map(payload), do: payload |> Map.get(field) |> integer_like()
  defp map_integer_value(_payload, _field), do: nil
  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value),
    do:
      case(Integer.parse(String.trim(value)),
        do: (
          {num, _} when num >= 0 -> num
          _ -> nil
        )
      )

  defp integer_like(_value), do: nil

  defp drop_blank_debug(%{debug: debug} = payload) do
    debug = debug |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
    if map_size(debug) == 0, do: Map.delete(payload, :debug), else: %{payload | debug: debug}
  end

  defp scrub_persisted_payload(%{} = payload), do: payload |> Enum.map(fn {key, value} -> if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, scrub_persisted_value(value)} end) |> Map.new()
  defp scrub_persisted_value(value) when is_binary(value), do: value |> Redaction.credentials() |> truncate_persisted_string()
  defp scrub_persisted_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp scrub_persisted_value(value) when is_map(value), do: scrub_persisted_payload(value)
  defp scrub_persisted_value(value) when is_list(value), do: Enum.map(value, &scrub_persisted_value/1)
  defp scrub_persisted_value(value), do: value
  defp truncate_persisted_string(value) when byte_size(value) > 1_000, do: binary_part(value, 0, 1_000) <> "... (truncated)"
  defp truncate_persisted_string(value), do: value
  defp sensitive_key?(key), do: key |> to_string() |> String.downcase() |> String.contains?(["token", "secret", "authorization", "api_key"])
end

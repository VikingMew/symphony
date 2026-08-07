defmodule SymphonyElixir.Codex.Protocol do
  @moduledoc """
  JSON-RPC framing and stream classification for the Codex app-server client.
  """

  alias SymphonyElixir.Payload

  defmodule Event do
    @moduledoc false

    @type t :: %__MODULE__{
            raw: map(),
            method: String.t() | nil,
            params: map(),
            id: term(),
            session_id: term(),
            thread_id: term(),
            turn_id: term(),
            item_id: term(),
            item_type: term(),
            item_status: term(),
            item_phase: term(),
            item_text: term(),
            turn_status: term(),
            turn_duration_ms: term(),
            usage: term(),
            input_tokens: non_neg_integer() | nil,
            output_tokens: non_neg_integer() | nil,
            total_tokens: non_neg_integer() | nil,
            rate_limits: term(),
            delta: term(),
            plan_entries: term(),
            command: term(),
            change_count: term(),
            question: term(),
            auth_mode: term(),
            message_type: term(),
            tool: term(),
            error_message: term(),
            response_error_message: term(),
            timestamp_ms: term(),
            timestamp_seconds: term()
          }

    defstruct raw: %{},
              method: nil,
              params: %{},
              id: nil,
              session_id: nil,
              thread_id: nil,
              turn_id: nil,
              item_id: nil,
              item_type: nil,
              item_status: nil,
              item_phase: nil,
              item_text: nil,
              turn_status: nil,
              turn_duration_ms: nil,
              usage: nil,
              input_tokens: nil,
              output_tokens: nil,
              total_tokens: nil,
              rate_limits: nil,
              delta: nil,
              plan_entries: nil,
              command: nil,
              change_count: nil,
              question: nil,
              auth_mode: nil,
              message_type: nil,
              tool: nil,
              error_message: nil,
              response_error_message: nil,
              timestamp_ms: nil,
              timestamp_seconds: nil
  end

  @max_stream_log_bytes 1_000
  @params_keys ["params", :params]
  @item_keys ["item", :item]
  @turn_keys ["turn", :turn]
  @message_keys ["msg", :msg]
  @payload_keys ["payload", :payload]

  @type decoded_line ::
          {:response_result, map()}
          | {:response_error, map()}
          | {:response_payload, map()}
          | {:other, term()}
          | {:malformed, String.t()}

  @type turn_item ::
          {:turn_completed, map(), String.t()}
          | {:turn_failed, map(), map(), String.t()}
          | {:turn_cancelled, map(), map(), String.t()}
          | {:notification, String.t(), map(), String.t()}
          | {:other, term(), String.t()}
          | {:malformed_candidate, String.t()}
          | {:stream_line, String.t()}

  @spec normalize_event(map(), String.t() | atom() | nil) :: Event.t()
  def normalize_event(payload, method \\ nil)

  def normalize_event(%Event{} = event, nil), do: event

  def normalize_event(%Event{} = event, method) do
    %{event | method: normalize_method(method)}
  end

  def normalize_event(payload, method) when is_map(payload) do
    raw = event_payload(payload, method)
    fallback = debug_raw_event(payload)
    method = normalized_method(method, raw, fallback)
    params = raw |> Payload.get_any(@params_keys, %{}) |> map_or_empty()
    item = params |> Payload.get_any(@item_keys, %{}) |> map_or_empty()
    turn = params |> Payload.get_any(@turn_keys, %{}) |> map_or_empty()
    usage = normalized_usage(raw, fallback, payload, method)
    token_usage = normalized_token_usage(raw, fallback, payload, method)
    counts = token_usage || usage

    %Event{
      raw: raw,
      method: method,
      params: params,
      id: event_id(raw, params),
      session_id: event_session_id(raw, params, payload),
      thread_id: event_thread_id(params),
      turn_id: event_turn_id(params, turn),
      item_id: event_item_id(params, item),
      item_type: Payload.get_any(item, ["type", :type]),
      item_status: Payload.get_any(item, ["status", :status]),
      item_phase: Payload.get_any(item, ["phase", :phase]),
      item_text: Payload.get_any(item, ["text", :text]),
      turn_status: Payload.get_any(turn, ["status", :status]),
      turn_duration_ms: Payload.get_any(turn, ["durationMs", :durationMs, "duration_ms", :duration_ms]),
      usage: usage,
      input_tokens: token_count(counts, :input),
      output_tokens: token_count(counts, :output),
      total_tokens: token_count(counts, :total),
      rate_limits: event_rate_limits(params, raw),
      delta: event_delta(params),
      plan_entries: first_value(params, [["plan", :plan], ["steps", :steps], ["items", :items]]),
      command:
        first_value(params, [
          ["parsedCmd", :parsedCmd],
          ["command", :command],
          ["cmd", :cmd],
          ["argv", :argv],
          ["args", :args]
        ]),
      change_count: first_value(params, [["fileChangeCount", :fileChangeCount], ["changeCount", :changeCount]]),
      question: first_value(params, [["question", :question], ["prompt", :prompt]]),
      auth_mode: Payload.get_any(params, ["authMode", :authMode, "auth_mode", :auth_mode]),
      message_type: Payload.get_path(params, [@message_keys, ["type", :type]]),
      tool: Payload.get_any(params, ["tool", :tool]),
      error_message: Payload.get_path(params, [["error", :error], ["message", :message]]),
      response_error_message: Payload.get_path(raw, [["response_error", :response_error], ["message", :message]]),
      timestamp_ms: event_timestamp_ms(params),
      timestamp_seconds: event_timestamp_seconds(turn)
    }
  end

  @spec encode_message(map()) :: iodata()
  def encode_message(message) when is_map(message) do
    [Jason.encode!(message), "\n"]
  end

  @spec complete_line(String.t(), term()) :: String.t()
  def complete_line(pending_line, chunk) when is_binary(pending_line) do
    pending_line <> to_string(chunk)
  end

  @spec decode_response_line(String.t(), term()) :: decoded_line()
  def decode_response_line(data, request_id) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:response_error, error}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:response_result, result}

      {:ok, %{"id" => ^request_id} = payload} ->
        {:response_payload, payload}

      {:ok, payload} ->
        {:other, payload}

      {:error, _reason} ->
        {:malformed, payload_string}
    end
  end

  @spec decode_turn_stream_line(String.t()) :: turn_item()
  def decode_turn_stream_line(data) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        {:turn_completed, payload, payload_string}

      {:ok, %{"method" => "turn/failed", "params" => params} = payload} ->
        {:turn_failed, payload, params, payload_string}

      {:ok, %{"method" => "turn/cancelled", "params" => params} = payload} ->
        {:turn_cancelled, payload, params, payload_string}

      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        {:notification, method, payload, payload_string}

      {:ok, payload} ->
        {:other, payload, payload_string}

      {:error, _reason} ->
        if protocol_message_candidate?(payload_string) do
          {:malformed_candidate, payload_string}
        else
          {:stream_line, payload_string}
        end
    end
  end

  @spec protocol_message_candidate?(term()) :: boolean()
  def protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  @spec stream_log_entry(term()) :: nil | {:debug | :warning, String.t()}
  def stream_log_entry(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    cond do
      text == "" ->
        nil

      String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) ->
        {:warning, text}

      true ->
        {:debug, text}
    end
  end

  defp normalized_method(method, raw, fallback) do
    normalize_method(method || event_method(raw) || event_method(fallback))
  end

  defp normalized_usage(raw, fallback, payload, method) do
    display_usage(raw, method) || display_usage(fallback, method) || display_usage(payload, method)
  end

  defp normalized_token_usage(raw, fallback, payload, method) do
    token_usage(raw, method) || token_usage(fallback, method) || token_usage(payload, method)
  end

  defp event_id(raw, params) do
    Payload.get_any(raw, ["id", :id]) || Payload.get_any(params, ["id", :id])
  end

  defp event_session_id(raw, params, payload) do
    keys = ["sessionId", :sessionId, "session_id", :session_id]
    Payload.get_any(raw, keys) || Payload.get_any(params, keys) || Payload.get_any(payload, keys)
  end

  defp event_thread_id(params) do
    keys = ["threadId", :threadId, "thread_id", :thread_id]

    Payload.get_any(params, keys) ||
      Payload.get_path(params, [@turn_keys, keys]) ||
      Payload.get_path(params, [["thread", :thread], ["id", :id]])
  end

  defp event_turn_id(params, turn) do
    Payload.get_any(params, ["turnId", :turnId, "turn_id", :turn_id]) ||
      Payload.get_any(turn, ["id", :id])
  end

  defp event_item_id(params, item) do
    Payload.get_any(item, ["id", :id]) ||
      Payload.get_any(params, ["id", :id]) ||
      Payload.get_any(params, ["itemId", :itemId, "item_id", :item_id]) ||
      Payload.get_path(params, [@message_keys, ["id", :id]])
  end

  defp event_rate_limits(params, raw) do
    keys = ["rateLimits", :rateLimits, "rate_limits", :rate_limits]
    Payload.get_any(params, keys) || Payload.get_any(raw, keys)
  end

  defp event_timestamp_ms(params) do
    Payload.get_any(params, ["completedAtMs", :completedAtMs, "completed_at_ms", :completed_at_ms]) ||
      Payload.get_any(params, ["startedAtMs", :startedAtMs, "started_at_ms", :started_at_ms])
  end

  defp event_timestamp_seconds(turn) do
    Payload.get_any(turn, ["completedAt", :completedAt, "completed_at", :completed_at]) ||
      Payload.get_any(turn, ["startedAt", :startedAt, "started_at", :started_at])
  end

  defp event_payload(payload, nil) do
    if event_method(payload) do
      payload
    else
      [Payload.get_any(payload, ["message", :message]), Payload.get_any(payload, @payload_keys)]
      |> Enum.find(payload, &is_map/1)
    end
  end

  defp event_payload(payload, _method), do: payload

  defp debug_raw_event(payload) do
    raw =
      Payload.get_path(payload, [["debug", :debug], ["raw", :raw]]) ||
        Payload.get_any(payload, ["raw", :raw])

    with raw when is_binary(raw) <- raw,
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
      decoded
    else
      _ -> %{}
    end
  end

  defp event_method(payload) when is_map(payload) do
    Payload.get_any(payload, ["method", :method]) ||
      Payload.get_path(payload, [@params_keys, ["method", :method]])
  end

  defp event_method(_payload), do: nil

  defp normalize_method(:turn_completed), do: "turn/completed"
  defp normalize_method(:item_completed), do: "item/completed"
  defp normalize_method(:thread_token_usage_updated), do: "thread/tokenUsage/updated"
  defp normalize_method(:account_rate_limits_updated), do: "account/rateLimits/updated"
  defp normalize_method(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method(method) when is_binary(method), do: method
  defp normalize_method(_method), do: nil

  defp display_usage(payload, "thread/tokenUsage/updated") when is_map(payload) do
    Payload.get_path(payload, [@params_keys, ["tokenUsage", :tokenUsage, "token_usage", :token_usage], ["total", :total]]) ||
      Payload.get_any(payload, ["usage", :usage])
  end

  defp display_usage(payload, "turn/completed") when is_map(payload) do
    Payload.get_path(payload, [@params_keys, ["usage", :usage]]) ||
      Payload.get_path(payload, [@params_keys, ["tokenUsage", :tokenUsage, "token_usage", :token_usage]]) ||
      Payload.get_any(payload, ["usage", :usage])
  end

  defp display_usage(_payload, _method), do: nil

  defp token_usage(payload, method) when is_map(payload) do
    explicit =
      find_token_usage(payload, [
        [@params_keys, @message_keys, @payload_keys, ["info", :info], ["total_token_usage", :total_token_usage]],
        [@params_keys, @message_keys, ["info", :info], ["total_token_usage", :total_token_usage]],
        [@params_keys, ["tokenUsage", :tokenUsage, "token_usage", :token_usage], ["total", :total]],
        [["tokenUsage", :tokenUsage, "token_usage", :token_usage], ["total", :total]],
        [["tokens", :tokens]],
        [@params_keys, ["tokens", :tokens]],
        [@params_keys, ["total_token_usage", :total_token_usage]]
      ])

    explicit ||
      token_map(display_usage(payload, method)) ||
      token_map(Payload.get_any(payload, ["usage", :usage])) ||
      token_map(payload)
  end

  defp token_usage(_payload, _method), do: nil

  defp find_token_usage(payload, paths) do
    Enum.find_value(paths, fn path ->
      payload
      |> Payload.get_path(path)
      |> token_map()
    end)
  end

  defp token_map(value) when is_map(value) do
    if Enum.any?([:input, :output, :total], &is_integer(token_count(value, &1))), do: value
  end

  defp token_map(_value), do: nil

  defp token_count(usage, kind) when is_map(usage) do
    usage
    |> first_value(token_key_groups(kind))
    |> non_negative_integer()
  end

  defp token_count(_usage, _kind), do: nil

  defp token_key_groups(:input),
    do: [
      ["input_tokens", :input_tokens],
      ["prompt_tokens", :prompt_tokens],
      ["inputTokens", :inputTokens],
      ["promptTokens", :promptTokens]
    ]

  defp token_key_groups(:output),
    do: [
      ["output_tokens", :output_tokens],
      ["completion_tokens", :completion_tokens],
      ["outputTokens", :outputTokens],
      ["completionTokens", :completionTokens]
    ]

  defp token_key_groups(:total),
    do: [["total_tokens", :total_tokens], ["total", :total], ["totalTokens", :totalTokens]]

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _remainder} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp event_delta(params) do
    [
      [["delta", :delta]],
      [@message_keys, ["delta", :delta]],
      [["textDelta", :textDelta]],
      [@message_keys, ["textDelta", :textDelta]],
      [["outputDelta", :outputDelta]],
      [@message_keys, ["outputDelta", :outputDelta]],
      [["text", :text]],
      [@message_keys, ["text", :text]],
      [["summaryText", :summaryText]],
      [@message_keys, ["summaryText", :summaryText]],
      [@message_keys, ["content", :content]],
      [@message_keys, @payload_keys, ["delta", :delta]],
      [@message_keys, @payload_keys, ["textDelta", :textDelta]],
      [@message_keys, @payload_keys, ["outputDelta", :outputDelta]],
      [@message_keys, @payload_keys, ["text", :text]],
      [@message_keys, @payload_keys, ["summaryText", :summaryText]],
      [@message_keys, @payload_keys, ["content", :content]]
    ]
    |> Enum.find_value(&Payload.get_path(params, &1))
  end

  defp first_value(map, key_groups) when is_map(map) do
    Enum.find_value(key_groups, &Payload.get_any(map, &1))
  end

  defp first_value(_map, _key_groups), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}
end

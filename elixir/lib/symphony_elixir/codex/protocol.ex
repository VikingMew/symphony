defmodule SymphonyElixir.Codex.Protocol do
  @moduledoc """
  JSON-RPC framing and stream classification for the Codex app-server client.
  """

  @max_stream_log_bytes 1_000

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
end

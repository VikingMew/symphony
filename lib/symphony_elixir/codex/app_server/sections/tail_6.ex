# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail6 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      require Logger

      alias SymphonyElixir.{
        Codex.DynamicTool,
        Codex.LinearToolAudit.PanelRecorder,
        Codex.Protocol,
        Codex.Startup,
        Codex.ToolRequestHandler,
        Config,
        PathSafety,
        Payload,
        RuntimeProxy,
        SSH
      }

      alias SymphonyElixir.Config.Schema

      defp handle_response(port, request_id, data, timeout_ms) do
        case Protocol.decode_response_line(data, request_id) do
          {:response_error, error} ->
            {:error, {:response_error, error}}

          {:response_result, result} ->
            {:ok, result}

          {:response_payload, response_payload} ->
            {:error, {:response_error, response_payload}}

          {:other, %{} = other} ->
            Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
            with_timeout_response(port, request_id, timeout_ms, "")

          {:other, _other} ->
            with_timeout_response(port, request_id, timeout_ms, "")

          {:malformed, payload} ->
            log_non_json_stream_line(payload, "response stream")
            with_timeout_response(port, request_id, timeout_ms, "")
        end
      end
    end
  end
end

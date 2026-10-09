# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail5 do
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

      defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
        receive do
          {^port, {:data, {:eol, chunk}}} ->
            complete_line = Protocol.complete_line(pending_line, chunk)
            handle_response(port, request_id, complete_line, timeout_ms)

          {^port, {:data, {:noeol, chunk}}} ->
            with_timeout_response(
              port,
              request_id,
              timeout_ms,
              Protocol.complete_line(pending_line, chunk)
            )

          {^port, {:exit_status, status}} ->
            {:error, {:port_exit, status}}

          {:EXIT, from, :shutdown} when is_pid(from) ->
            {:error, :cancelled}
        after
          timeout_ms -> {:error, :response_timeout}
        end
      end
    end
  end
end

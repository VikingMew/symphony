# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail4 do
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

      defp param(params, "outcome") do
        Payload.get_any(params, ["outcome", :outcome])
      end

      defp param(params, "status") do
        Payload.get_any(params, ["status", :status])
      end

      defp param(params, "reason") do
        Payload.get_any(params, ["reason", :reason])
      end

      defp param(params, "detail") do
        Payload.get_any(params, ["detail", :detail])
      end

      defp param(params, "references") do
        Payload.get_any(params, ["references", :references])
      end

      defp await_response(port, request_id) do
        with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
      end
    end
  end
end

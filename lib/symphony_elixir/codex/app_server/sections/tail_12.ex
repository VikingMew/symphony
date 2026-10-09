# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail12 do
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

      defp send_message(port, message) do
        Port.command(port, Protocol.encode_message(message))
      end
    end
  end
end

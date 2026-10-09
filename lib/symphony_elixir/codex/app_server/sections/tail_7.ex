# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail7 do
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

      defp log_non_json_stream_line(data, stream_label) do
        case Protocol.stream_log_entry(data) do
          {:warning, text} -> Logger.warning("Codex #{stream_label} output: #{text}")
          {:debug, text} -> Logger.debug("Codex #{stream_label} output: #{text}")
          nil -> :ok
        end
      end

      defp issue_context(%{id: issue_id, identifier: identifier}) do
        "issue_id=#{issue_id} issue_identifier=#{identifier}"
      end
    end
  end
end

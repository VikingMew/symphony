# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail10 do
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

      defp signal_os_process(pid, signal) do
        System.cmd("sh", ["-c", "kill -#{signal} \"$1\"", "kill", pid], stderr_to_stdout: true)
      end

      defp os_process_alive?(pid) do
        case System.cmd("sh", ["-c", "kill -0 \"$1\"", "kill", pid], stderr_to_stdout: true) do
          {_output, 0} -> true
          {_output, _status} -> false
        end
      end

      defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
        message =
          metadata
          |> Map.merge(details)
          |> Map.put(:event, event)
          |> Map.put(:timestamp, DateTime.utc_now())

        on_message.(message)
      end
    end
  end
end

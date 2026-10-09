# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail9 do
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

      defp terminate_os_process(pid) when is_binary(pid) do
        signal_os_process(pid, "TERM")
        await_os_process_exit(pid, @os_process_shutdown_grace_ms)
      end

      defp await_os_process_exit(pid, remaining_ms) when remaining_ms <= 0 do
        if os_process_alive?(pid) do
          signal_os_process(pid, "KILL")
        end

        :ok
      end

      defp await_os_process_exit(pid, remaining_ms) do
        if os_process_alive?(pid) do
          Process.sleep(@os_process_shutdown_poll_ms)
          await_os_process_exit(pid, remaining_ms - @os_process_shutdown_poll_ms)
        else
          :ok
        end
      end
    end
  end
end

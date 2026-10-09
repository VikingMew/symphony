# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail8 do
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

      defp stop_port(port) when is_port(port) do
        case :erlang.port_info(port) do
          :undefined ->
            :ok

          _ ->
            try do
              Port.close(port)
              :ok
            rescue
              ArgumentError -> :ok
            end
        end
      end

      defp terminate_os_process(nil) do
        :ok
      end
    end
  end
end

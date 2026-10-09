# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail11 do
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

      defp metadata_from_message(port, payload) do
        port |> port_metadata(nil) |> maybe_set_usage(payload)
      end

      defp maybe_set_usage(metadata, payload) when is_map(payload) do
        usage = SymphonyElixir.Payload.get_any(payload, ["usage", :usage])

        if is_map(usage) do
          Map.put(metadata, :usage, usage)
        else
          metadata
        end
      end

      defp maybe_set_usage(metadata, _payload) do
        metadata
      end

      defp default_on_message(_message) do
        :ok
      end
    end
  end
end

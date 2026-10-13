# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail do
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

      defp turn_error_detail("error", payload, current) do
        params = Payload.get_any(payload, ["params", :params], %{})
        error = Payload.get_any(params, ["error", :error], %{})
        codex_error_info = Payload.get_any(error, ["codexErrorInfo", :codexErrorInfo])
        will_retry = Payload.get_any(params, ["willRetry", :willRetry])
        detail = %{} |> put_codex_error_info(codex_error_info) |> put_will_retry(will_retry)

        if map_size(detail) == 0 do
          current
        else
          detail
        end
      end

      defp turn_error_detail(_method, _payload, current) do
        current
      end

      defp put_codex_error_info(detail, value) when is_binary(value) do
        Map.put(detail, "codex_error_info", String.slice(value, 0, 128))
      end
    end
  end
end

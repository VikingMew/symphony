# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.AppServer.Sections.Tail3 do
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

      defp normalize_failed_turn(params) do
        case param(params, "outcome") || param(params, "status") do
          outcome when outcome in ["blocked", :blocked] ->
            {:blocked,
             %{
               reason: param(params, "reason") || "blocked",
               detail: param(params, "detail") || params,
               references: param(params, "references") || %{}
             }}

          outcome when outcome in [nil, "failed", :failed] ->
            {:error, {:turn_failed, params}}

          outcome ->
            {:error, {:invalid_turn_outcome, outcome, params}}
        end
      end

      defp blocked_outcome(reason, payload) do
        %{reason: reason, detail: payload, references: %{}}
      end
    end
  end
end

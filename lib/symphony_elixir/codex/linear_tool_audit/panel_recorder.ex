defmodule SymphonyElixir.Codex.LinearToolAudit.PanelRecorder do
  @moduledoc "Panel-local persistence recorder for restricted Linear tool audits."

  alias SymphonyElixir.PersistenceEventWriter

  @spec record(map(), map()) :: :ok | {:degraded, term()} | {:error, term()}
  def record(attrs, context), do: PersistenceEventWriter.record(attrs, context)
end

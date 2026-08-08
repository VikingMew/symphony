defmodule SymphonyElixirWeb.WebRuntime do
  @moduledoc """
  Provides the runtime dependencies used by the observability web interface.
  """

  @endpoint_config_key :"Elixir.SymphonyElixirWeb.Endpoint"

  @spec orchestrator() :: GenServer.name()
  def orchestrator do
    Keyword.get(endpoint_config(), :orchestrator) || SymphonyElixir.Orchestrator
  end

  @spec snapshot_timeout_ms() :: timeout()
  def snapshot_timeout_ms do
    Keyword.get(endpoint_config(), :snapshot_timeout_ms) || 15_000
  end

  defp endpoint_config do
    Application.get_env(:symphony_elixir, @endpoint_config_key, [])
  end
end

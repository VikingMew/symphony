defmodule SymphonyElixir.Worker.Config do
  @moduledoc "Runtime configuration for the separately deployed execution worker."

  @enforce_keys [:panel_url, :registration_token, :worker_name, :workspace_root, :cache_root, :log_root]
  defstruct @enforce_keys ++ [slots: 1, image_reference: "unknown", source_revision: "unknown"]

  @type t :: %__MODULE__{
          panel_url: String.t(), registration_token: String.t(), worker_name: String.t(),
          workspace_root: Path.t(), cache_root: Path.t(), log_root: Path.t(), slots: pos_integer(),
          image_reference: String.t(), source_revision: String.t()
        }

  @spec load!() :: t()
  def load! do
    :symphony_elixir
    |> Application.fetch_env!(:worker)
    |> then(&struct!(__MODULE__, &1))
  end
end

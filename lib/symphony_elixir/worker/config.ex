defmodule SymphonyElixir.Worker.Config do
  @moduledoc "Runtime configuration for the separately deployed execution worker."

  @enforce_keys [:panel_url, :registration_token, :worker_name, :workspace_root, :cache_root, :log_root]
  defstruct @enforce_keys ++
              [
                slots: 1,
                retention_seconds: 86_400,
                cache_max_bytes: 10_737_418_240,
                image_reference: "unknown",
                source_revision: "unknown",
                request_options: [],
                client_module: SymphonyElixir.Worker.Client,
                executor_module: SymphonyElixir.Worker.Executor,
                task_supervisor: SymphonyElixir.Worker.TaskSupervisor,
                lifecycle_retry_seconds: 2,
                lifecycle_max_attempts: 5,
                executor_start_timeout_seconds: 30
              ]

  @type t :: %__MODULE__{
          panel_url: String.t(),
          registration_token: String.t(),
          worker_name: String.t(),
          workspace_root: Path.t(),
          cache_root: Path.t(),
          log_root: Path.t(),
          slots: pos_integer(),
          retention_seconds: pos_integer(),
          cache_max_bytes: pos_integer(),
          image_reference: String.t(),
          source_revision: String.t(),
          request_options: keyword(),
          client_module: module(),
          executor_module: module(),
          task_supervisor: GenServer.server(),
          lifecycle_retry_seconds: pos_integer(),
          lifecycle_max_attempts: pos_integer(),
          executor_start_timeout_seconds: pos_integer()
        }

  @spec load!() :: t()
  def load! do
    :symphony_elixir
    |> Application.fetch_env!(:worker)
    |> then(&struct!(__MODULE__, &1))
  end
end

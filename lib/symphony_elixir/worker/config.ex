defmodule SymphonyElixir.Worker.Config do
  @moduledoc "Runtime configuration for a separately deployed execution surface."

  alias SymphonyElixir.HostProbe.Token

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
                executor_start_timeout_seconds: 30,
                execution_surface: "container_worker",
                probe_id: nil,
                capabilities: [],
                token_file: nil,
                codex_launcher: nil,
                local_deadline_seconds: 30
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
          executor_start_timeout_seconds: pos_integer(),
          execution_surface: String.t(),
          probe_id: String.t() | nil,
          capabilities: [String.t()],
          token_file: Path.t() | nil,
          codex_launcher: String.t() | nil,
          local_deadline_seconds: pos_integer()
        }

  @spec load!() :: t()
  def load! do
    config = :symphony_elixir |> Application.fetch_env!(:worker) |> then(&struct!(__MODULE__, &1))

    case config.execution_surface do
      "host_probe" -> load_host_probe!(config)
      "container_worker" -> config
    end
  end

  defp load_host_probe!(config) do
    with "http://127.0.0.1:4001" <- config.panel_url,
         "local-host" <- config.probe_id,
         launcher when is_binary(launcher) and launcher != "" <- config.codex_launcher,
         {:ok, token} <- Token.load_bearer(config.token_file) do
      %{config | registration_token: token, slots: 1, local_deadline_seconds: 30}
    else
      reason -> raise ArgumentError, "invalid host probe configuration: #{inspect(reason)}"
    end
  end
end

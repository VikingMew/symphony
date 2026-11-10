defmodule SymphonyElixir.HostProbe.HostConfig do
  @moduledoc "Operator-owned configuration for the host-probe process."

  alias SymphonyElixir.ExecutionRequirement
  alias SymphonyElixir.HostProbe.{HostClient, HostExecutor}

  @panel_url "http://127.0.0.1:4001"
  @probe_id "local-host"
  @heartbeat_seconds 5
  @lease_seconds 30
  @local_deadline_seconds 30

  @enforce_keys [:token_file, :registration_token, :workspace_root, :launcher]
  defstruct @enforce_keys ++
              [
                panel_url: @panel_url,
                probe_id: @probe_id,
                worker_name: @probe_id,
                capabilities: [],
                capability_digest: nil,
                heartbeat_seconds: @heartbeat_seconds,
                lease_seconds: @lease_seconds,
                local_deadline_seconds: @local_deadline_seconds,
                lifecycle_retry_seconds: 2,
                source_revision: "unknown",
                image_reference: "host-probe",
                request_options: [],
                client_module: HostClient,
                execute_assignment: &HostExecutor.execute_host_assignment/3,
                task_supervisor: SymphonyElixir.HostProbe.TaskSupervisor,
                now_ms: &__MODULE__.host_monotonic_ms/0,
                send_after: &Process.send_after/3,
                cancel_timer: &Process.cancel_timer/1
              ]

  @type host_config :: %__MODULE__{
          token_file: Path.t(),
          registration_token: String.t(),
          workspace_root: Path.t(),
          launcher: String.t(),
          panel_url: String.t(),
          probe_id: String.t(),
          worker_name: String.t(),
          capabilities: [String.t()],
          capability_digest: String.t() | nil,
          heartbeat_seconds: pos_integer(),
          lease_seconds: pos_integer(),
          local_deadline_seconds: pos_integer(),
          lifecycle_retry_seconds: pos_integer(),
          source_revision: String.t(),
          image_reference: String.t(),
          request_options: keyword(),
          client_module: module(),
          execute_assignment: (host_config(), map(), (String.t(), map() -> term()) -> map()),
          task_supervisor: GenServer.server(),
          now_ms: (-> integer()),
          send_after: (pid(), term(), non_neg_integer() -> reference()),
          cancel_timer: (reference() -> term())
        }

  @spec load_host_config!() :: host_config()
  def load_host_config! do
    attrs = Application.fetch_env!(:symphony_elixir, :host_probe)
    token_file = Keyword.fetch!(attrs, :token_file)
    token = read_host_token!(token_file)

    {:ok, capabilities} =
      attrs
      |> Keyword.get(:capabilities, [])
      |> ExecutionRequirement.normalize_capabilities()

    %__MODULE__{
      token_file: token_file,
      registration_token: token,
      workspace_root: Keyword.fetch!(attrs, :workspace_root),
      launcher: Keyword.fetch!(attrs, :launcher),
      capabilities: capabilities,
      capability_digest: ExecutionRequirement.capability_digest(capabilities),
      source_revision: Keyword.get(attrs, :source_revision, "unknown")
    }
  end

  @spec read_host_token!(Path.t()) :: String.t()
  def read_host_token!(path) when is_binary(path) do
    token = path |> File.read!() |> String.trim()
    if token == "", do: raise(ArgumentError, "HOST_PROBE_TOKEN_FILE is empty"), else: token
  end

  @spec fixed_panel_url() :: String.t()
  def fixed_panel_url, do: @panel_url

  @doc false
  @spec host_monotonic_ms() :: integer()
  def host_monotonic_ms, do: System.monotonic_time(:millisecond)
end

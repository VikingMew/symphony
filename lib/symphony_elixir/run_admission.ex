defmodule SymphonyElixir.RunAdmission do
  @moduledoc """
  Resolves the immutable execution decision used to create and run one task.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkspacePreflight

  @enforce_keys [:execution_mode, :workspace_authority, :source, :limits]
  defstruct [:execution_mode, :workspace_authority, :source, :limits]

  @type execution_mode :: String.t()
  @type workspace_authority ::
          {:panel_local}
          | {:centralized_ssh, String.t()}
          | {:http_worker, String.t(), String.t()}
  @type cleanup_authority :: {:panel_local} | {:centralized_ssh, String.t()}
  @type run_subject :: {:issue, Issue.t()} | {:operator, map()}
  @type readiness_result :: :ready | :ok | {:error, map()}
  @type readiness_adapter :: (workspace_authority(), Schema.t() -> :ok | {:error, map()})
  @type execution_context :: %{
          required(:workspace_authority) => workspace_authority(),
          optional(:readiness) => readiness_result() | readiness_adapter(),
          optional(:preflight_opts) => keyword()
        }
  @type source :: %{
          repository: String.t() | nil,
          default_branch: String.t(),
          implementation_branch: String.t() | nil,
          source_strategy: String.t(),
          checkout_depth: pos_integer()
        }
  @type limits :: %{
          initialize_timeout_ms: pos_integer(),
          max_turns: pos_integer(),
          max_failure_retries: non_neg_integer(),
          retry_backoff_ms: pos_integer(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }
  @type t :: %__MODULE__{
          execution_mode: execution_mode(),
          workspace_authority: workspace_authority(),
          source: source(),
          limits: limits()
        }

  @spec execution_mode() :: execution_mode()
  def execution_mode do
    case Config.execution_mode() do
      :centralized -> "centralized"
      :worker -> "worker"
    end
  end

  @spec cleanup_authorities(Workflow.loaded_workflow()) :: [cleanup_authority()]
  def cleanup_authorities(%{config: config}) do
    mode = execution_mode()

    if mode == "worker" do
      []
    else
      {:ok, settings} = Schema.parse(config)

      case settings.worker.ssh_hosts do
        [] -> [{:panel_local}]
        hosts -> Enum.map(hosts, &{:centralized_ssh, &1})
      end
    end
  end

  @spec resolve(Workflow.loaded_workflow(), run_subject(), execution_context()) ::
          {:ok, t()} | {:error, {:environment_unavailable, map()}}
  def resolve(%{config: config}, subject, %{workspace_authority: authority} = context) do
    {:ok, settings} = Schema.parse(config)
    mode = execution_mode()

    with :ok <- validate_surface(mode, authority),
         :ok <- check_readiness(authority, settings, context) do
      {:ok,
       %__MODULE__{
         execution_mode: mode,
         workspace_authority: authority,
         source: source(settings, subject),
         limits: limits(settings)
       }}
    end
  end

  defp validate_surface("centralized", authority)
       when authority == {:panel_local} or elem(authority, 0) == :centralized_ssh,
       do: :ok

  defp validate_surface("worker", {:http_worker, _worker_id, _session_id}), do: :ok

  defp validate_surface(mode, authority) do
    unavailable(authority, %{kind: :execution_mode_unavailable, execution_mode: mode})
  end

  defp check_readiness({:panel_local} = authority, settings, context) do
    opts = context |> Map.get(:preflight_opts, []) |> Keyword.put(:settings, settings)

    case WorkspacePreflight.check(:pre_listen, opts) do
      :ok -> :ok
      {:error, rejection} -> unavailable(authority, rejection)
    end
  end

  defp check_readiness({:centralized_ssh, _host} = authority, settings, context) do
    readiness = Map.fetch!(context, :readiness)

    case readiness.(authority, settings) do
      :ok -> :ok
      {:error, rejection} -> unavailable(authority, rejection)
    end
  end

  defp check_readiness({:http_worker, _worker_id, _session_id} = authority, _settings, context) do
    case Map.fetch!(context, :readiness) do
      :ready -> :ok
      {:error, rejection} -> unavailable(authority, rejection)
    end
  end

  defp unavailable(authority, rejection) do
    evidence =
      rejection
      |> Map.put(:surface, surface(authority))
      |> Map.put(:workspace_authority, authority)

    {:error, {:environment_unavailable, evidence}}
  end

  defp surface({:panel_local}), do: :panel_local
  defp surface({:centralized_ssh, _host}), do: :centralized_ssh
  defp surface({:http_worker, _worker_id, _session_id}), do: :http_worker

  defp source(settings, subject) do
    %{
      repository: settings.project.repository_url,
      default_branch: settings.project.default_branch,
      implementation_branch: implementation_branch(subject),
      source_strategy: settings.project.source_strategy,
      checkout_depth: settings.project.checkout_depth
    }
  end

  defp implementation_branch({:issue, %Issue{} = issue}), do: issue.branch_name
  defp implementation_branch({:operator, _task}), do: nil

  defp limits(settings) do
    %{
      initialize_timeout_ms: settings.workspace.initialize_timeout_ms,
      max_turns: settings.agent.max_turns,
      max_failure_retries: settings.agent.max_failure_retries,
      retry_backoff_ms: settings.agent.max_retry_backoff_ms,
      turn_timeout_ms: settings.codex.turn_timeout_ms,
      read_timeout_ms: settings.codex.read_timeout_ms,
      stall_timeout_ms: settings.codex.stall_timeout_ms
    }
  end
end

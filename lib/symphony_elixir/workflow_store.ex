defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the active database workflow version for every enabled project.

  The runtime source is the active workflow version per project in SQLite. Each
  enabled project that has an active workflow version contributes one loaded
  workflow, keyed by project id. `current/0` and `current_with_source/0` keep
  single-workflow compatibility and return the default project's workflow (or
  the first enabled project's workflow when the default has none).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{PersistenceProvider, Workflow}

  @poll_interval_ms 1_000

  @type current_error :: :no_active_workflow | :repo_unavailable | {:query_failed, term()}

  defmodule State do
    @moduledoc false

    defstruct [:workflows, :default_project_id, :source]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, current_error()}
  def current do
    with {:ok, %{workflow: workflow}} <- current_with_source() do
      {:ok, workflow}
    end
  end

  @spec current_with_source() ::
          {:ok, %{workflow: Workflow.loaded_workflow(), source: map()}} | {:error, current_error()}
  def current_with_source do
    current_with_source_payload()
  end

  @spec list_enabled() :: [Workflow.loaded_workflow()]
  def list_enabled do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:ok, workflows} = GenServer.call(__MODULE__, :list_enabled)
        workflows

      _ ->
        %State{workflows: workflows} = load_initial_state()
        Map.values(workflows)
    end
  end

  @spec for_project(term()) :: {:ok, Workflow.loaded_workflow()} | {:error, :not_found | :setup_required}
  def for_project(project_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, {:for_project, project_id})

      _ ->
        %State{workflows: workflows} = load_initial_state()

        case Map.get(workflows, project_id) do
          nil -> {:error, :not_found}
          workflow -> {:ok, workflow}
        end
    end
  end

  @spec force_reload() :: :ok
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        _state = load_initial_state()
        :ok
    end
  end

  defp current_with_source_payload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current_with_source)

      _ ->
        load_current_state()
    end
  end

  defp load_current_state do
    case load_state() do
      {:ok, state} -> state_payload(state)
      {:error, reason} -> {:error, normalize_current_error(reason)}
    end
  rescue
    error -> {:error, {:query_failed, error}}
  catch
    kind, reason -> {:error, {:query_failed, {kind, reason}}}
  end

  @impl true
  def init(_opts) do
    state = load_initial_state()
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:current_with_source, _from, %State{} = state) do
    new_state = reload_state(state)
    {:reply, state_payload(new_state), new_state}
  end

  def handle_call(:list_enabled, _from, %State{} = state) do
    new_state = reload_state(state)
    {:reply, {:ok, Map.values(new_state.workflows)}, new_state}
  end

  def handle_call({:for_project, project_id}, _from, %State{} = state) do
    new_state = reload_state(state)

    result =
      case Map.get(new_state.workflows, project_id) do
        nil -> {:error, :not_found}
        workflow -> {:ok, workflow}
      end

    {:reply, result, new_state}
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    new_state = reload_state(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    new_state = reload_state(state)
    {:noreply, new_state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    case load_state() do
      {:ok, new_state} ->
        new_state

      {:error, reason} ->
        log_reload_failure(:error, reason)
        retain_loaded_or_mark_error(state, reason)
    end
  rescue
    error ->
      log_reload_failure(:error, error)
      retain_loaded_or_mark_error(state, {:query_failed, error})
  catch
    kind, reason ->
      log_reload_failure(kind, reason)
      retain_loaded_or_mark_error(state, {:query_failed, {kind, reason}})
  end

  defp retain_loaded_or_mark_error(%State{workflows: workflows} = state, _reason)
       when map_size(workflows) > 0,
       do: state

  defp retain_loaded_or_mark_error(%State{} = state, reason) do
    %{state | source: %{type: :error, reason: normalize_current_error(reason)}}
  end

  defp load_state do
    case load_database_workflows() do
      {:ok, workflows, default_project_id} ->
        {:ok,
         %State{
           workflows: workflows,
           default_project_id: default_project_id,
           source: database_source(workflows)
         }}

      :setup_required ->
        {:ok, setup_required_state()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_initial_state do
    case load_state() do
      {:ok, state} ->
        state

      {:error, :repo_unavailable} ->
        Logger.warning("Workflow database load degraded action=use_error_state reason=repo_unavailable")
        repo_unavailable_state()

      {:error, reason} ->
        raise "Workflow database load failed reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}"
    end
  rescue
    error ->
      log_initial_load_failure(:error, error)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      log_initial_load_failure(kind, reason)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp load_database_workflows do
    if database_workflow_enabled?(), do: load_enabled_database_workflows(), else: :setup_required
  end

  defp load_enabled_database_workflows do
    with {:ok, default_project} <- load_default_project(),
         {:ok, workflows} <- load_project_workflows() do
      if map_size(workflows) == 0 do
        :setup_required
      else
        {:ok, workflows, default_project_id(workflows, default_project)}
      end
    end
  end

  defp load_default_project do
    case persistence().default_project() do
      {:ok, project} -> {:ok, project}
      {:error, :repo_unavailable} = error -> error
      {:error, reason} -> {:error, {:default_project, reason}}
    end
  end

  defp load_project_workflows do
    case persistence().list_projects() do
      projects when is_list(projects) ->
        projects
        |> Enum.filter(&Map.get(&1, :enabled, true))
        |> Enum.reduce_while({:ok, %{}}, &load_project_workflow/2)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_list_projects_result, other}}
    end
  end

  defp load_project_workflow(project, {:ok, workflows}) do
    case persistence().active_workflow_version(project) do
      nil ->
        {:cont, {:ok, workflows}}

      {:error, :repo_unavailable} = error ->
        {:halt, error}

      {:error, reason} ->
        {:halt, {:error, {:active_workflow_version, Map.get(project, :id), reason}}}

      workflow_version ->
        loaded = persistence().workflow_to_loaded(workflow_version)
        {:cont, {:ok, Map.put(workflows, Map.fetch!(project, :id), loaded)}}
    end
  end

  defp default_project_id(workflows, default_project) do
    case default_project do
      %{id: id} when is_map_key(workflows, id) -> id
      _ -> workflows |> Map.keys() |> List.first()
    end
  end

  defp database_workflow_enabled? do
    Application.get_env(:symphony_elixir, :workflow_source) in [nil, :database, "database"]
  end

  defp persistence, do: PersistenceProvider.module()

  defp database_source(workflows) do
    %{
      type: :database,
      workflow_versions:
        Map.new(workflows, fn {project_id, workflow} ->
          {project_id, Map.get(workflow, :workflow_version_id)}
        end)
    }
  end

  defp setup_required_state do
    %State{workflows: %{}, default_project_id: nil, source: %{type: :setup_required}}
  end

  defp repo_unavailable_state do
    %State{
      workflows: %{},
      default_project_id: nil,
      source: %{type: :error, reason: :repo_unavailable}
    }
  end

  defp log_reload_failure(kind, reason) do
    Logger.error("Workflow reload failed action=retain_last_known_good kind=#{kind} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
  end

  defp log_initial_load_failure(kind, reason) do
    Logger.error("Workflow database load failed action=propagate kind=#{kind} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
  end

  defp state_payload(%State{source: %{type: :error, reason: reason}}),
    do: {:error, normalize_current_error(reason)}

  defp state_payload(%State{source: %{type: :setup_required} = source}) do
    workflow = Workflow.setup_required_workflow(Application.get_env(:symphony_elixir, :server_port_override))
    {:ok, %{workflow: workflow, source: source}}
  end

  defp state_payload(%State{workflows: workflows, default_project_id: default_id, source: source}) do
    case Map.get(workflows, default_id) do
      nil -> {:error, :no_active_workflow}
      workflow -> {:ok, %{workflow: workflow, source: source}}
    end
  end

  defp normalize_current_error(:repo_unavailable), do: :repo_unavailable
  defp normalize_current_error({:query_failed, _reason} = error), do: error
  defp normalize_current_error(reason), do: {:query_failed, reason}
end

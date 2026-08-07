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

  alias SymphonyElixir.{PersistenceProvider, Workflow}

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:workflows, :default_project_id, :source]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()}
  def current do
    {:ok, current_with_source_payload().workflow}
  end

  @spec current_with_source() :: {:ok, %{workflow: Workflow.loaded_workflow(), source: map()}}
  def current_with_source do
    {:ok, current_with_source_payload()}
  end

  @spec list_enabled() :: [Workflow.loaded_workflow()]
  def list_enabled do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:ok, workflows} = GenServer.call(__MODULE__, :list_enabled)
        workflows

      _ ->
        %State{workflows: workflows} = load_state()
        Map.values(workflows)
    end
  end

  @spec for_project(term()) :: {:ok, Workflow.loaded_workflow()} | {:error, :not_found | :setup_required}
  def for_project(project_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, {:for_project, project_id})

      _ ->
        %State{workflows: workflows} = load_state()

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
        _state = load_state()
        :ok
    end
  end

  defp current_with_source_payload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:ok, payload} = GenServer.call(__MODULE__, :current_with_source)
        payload

      _ ->
        state_payload(load_state())
    end
  end

  @impl true
  def init(_opts) do
    state = load_state()
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:current_with_source, _from, %State{} = state) do
    new_state = reload_state(state)
    {:reply, {:ok, state_payload(new_state)}, new_state}
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

  defp reload_state(%State{}) do
    load_state()
  end

  defp load_state do
    case load_database_workflows() do
      {:ok, workflows} when map_size(workflows) > 0 ->
        %State{
          workflows: workflows,
          default_project_id: default_project_id(workflows),
          source: database_source(workflows)
        }

      _ ->
        setup_required_state()
    end
  end

  defp load_database_workflows do
    if database_workflow_enabled?() do
      workflows =
        persistence().list_projects()
        |> Enum.filter(&Map.get(&1, :enabled, true))
        |> Enum.reduce(%{}, &load_project_workflow/2)

      if map_size(workflows) == 0, do: :setup_required, else: {:ok, workflows}
    else
      :setup_required
    end
  rescue
    _error -> :setup_required
  end

  defp load_project_workflow(project, workflows) do
    case persistence().active_workflow_version(project) do
      nil ->
        workflows

      workflow_version ->
        loaded = persistence().workflow_to_loaded(workflow_version)
        Map.put(workflows, Map.fetch!(project, :id), loaded)
    end
  end

  defp default_project_id(workflows) do
    case persistence().default_project() do
      {:ok, %{id: id}} when is_map_key(workflows, id) -> id
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

  defp state_payload(%State{workflows: workflows, default_project_id: default_id, source: source}) do
    workflow =
      case Map.get(workflows, default_id) do
        nil ->
          Workflow.setup_required_workflow(Application.get_env(:symphony_elixir, :server_port_override))

        workflow ->
          workflow
      end

    %{workflow: workflow, source: source}
  end
end

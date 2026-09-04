defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Publishes the current database workflow for every enabled project.

  PostgreSQL is the durable runtime snapshot synchronized from the repository
  package, while runtime reads use one atomically replaced in-memory snapshot.
  The owner process performs initial and explicit loads and
  coordinates one background refresh; callers never query persistence or wait
  for that work.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{PersistenceProvider, Workflow}

  @poll_interval_ms 1_000
  @snapshot_key {__MODULE__, :published_snapshot}

  @type current_error :: :no_active_workflow | :repo_unavailable | {:query_failed, term()}
  @type refresh_error :: {:refresh_failed, current_error() | :cache_unavailable}

  defmodule State do
    @moduledoc false

    defstruct [:workflows, :default_project_id, :source, :generation, :refresh]
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
    published_snapshot()
    |> state_payload()
  end

  @spec list_enabled() :: [Workflow.loaded_workflow()]
  def list_enabled do
    published_snapshot()
    |> Map.fetch!(:workflows)
    |> Map.values()
  end

  @spec for_project(term()) :: {:ok, Workflow.loaded_workflow()} | {:error, :not_found}
  def for_project(project_id) do
    case get_in(published_snapshot(), [:workflows, project_id]) do
      nil -> {:error, :not_found}
      workflow -> {:ok, workflow}
    end
  end

  @doc """
  Reloads and atomically publishes the complete durable workflow snapshot.

  This call may wait for persistence, but public reads remain independent. A
  failed load preserves the last published snapshot and is reported explicitly.
  """
  @spec force_reload() :: :ok | {:error, refresh_error()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(__MODULE__, :force_reload, :infinity)
      _ -> {:error, {:refresh_failed, :cache_unavailable}}
    end
  end

  @impl true
  def init(_opts) do
    state = load_initial_state()

    if registered_owner?() do
      publish(state)
    end

    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:force_reload, _from, %State{} = state) do
    generation = state.generation + 1
    guarded_state = %{state | generation: generation}

    case safe_load_state() do
      {:ok, loaded_state} ->
        new_state = %{loaded_state | generation: generation, refresh: state.refresh}
        publish(new_state)
        {:reply, :ok, new_state}

      {:error, reason} ->
        log_reload_failure(:explicit, :error, reason)
        {:reply, {:error, {:refresh_failed, normalize_current_error(reason)}}, guarded_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()
    {:noreply, maybe_start_refresh(state)}
  end

  def handle_info(
        {:workflow_refresh_result, token, start_generation, result},
        %State{refresh: %{token: token, monitor: monitor}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    state = %{state | refresh: nil}
    {:noreply, handle_refresh_result(state, start_generation, result)}
  end

  def handle_info({:workflow_refresh_result, _token, _generation, _result}, %State{} = state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %State{refresh: %{monitor: monitor}} = state
      ) do
    if reason != :normal do
      log_reload_failure(:background, :exit, reason)
    end

    {:noreply, %{state | refresh: nil}}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, %State{} = state) do
    {:noreply, state}
  end

  defp maybe_start_refresh(%State{refresh: nil} = state) do
    owner = self()
    token = make_ref()
    start_generation = state.generation

    {pid, monitor} =
      spawn_monitor(fn ->
        send(owner, {
          :workflow_refresh_result,
          token,
          start_generation,
          safe_load_state()
        })
      end)

    %{state | refresh: %{token: token, monitor: monitor, pid: pid}}
  end

  defp maybe_start_refresh(%State{} = state), do: state

  defp handle_refresh_result(%State{} = state, start_generation, {:ok, loaded_state})
       when start_generation == state.generation do
    new_state = %{loaded_state | generation: state.generation + 1, refresh: nil}
    publish(new_state)
    new_state
  end

  defp handle_refresh_result(%State{} = state, start_generation, {:ok, _loaded_state}) do
    Logger.info(
      "Workflow refresh skipped action=discard_stale_generation " <>
        "refresh_generation=#{start_generation} current_generation=#{state.generation}"
    )

    state
  end

  defp handle_refresh_result(%State{} = state, _start_generation, {:error, reason}) do
    log_reload_failure(:background, :error, reason)
    state
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp registered_owner? do
    Process.info(self(), :registered_name) == {:registered_name, __MODULE__}
  end

  defp safe_load_state do
    load_state()
  rescue
    error -> {:error, {:query_failed, error}}
  catch
    kind, reason -> {:error, {:query_failed, {kind, reason}}}
  end

  defp load_state do
    case load_database_workflows() do
      {:ok, workflows, default_project_id} ->
        {:ok,
         %State{
           workflows: workflows,
           default_project_id: default_project_id,
           source: database_source(workflows, default_project_id),
           generation: 0,
           refresh: nil
         }}

      :setup_required ->
        {:ok, setup_required_state()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_initial_state do
    case safe_load_state() do
      {:ok, state} ->
        state

      {:error, reason} ->
        log_reload_failure(:initial, :error, reason)
        error_state(reason)
    end
  end

  defp load_database_workflows do
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
      {:error, :not_found} -> {:ok, nil}
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
    case persistence().current_workflow(project) do
      nil ->
        {:cont, {:ok, workflows}}

      {:error, :repo_unavailable} = error ->
        {:halt, error}

      {:error, reason} ->
        {:halt, {:error, {:current_workflow, Map.get(project, :id), reason}}}

      workflow ->
        loaded = persistence().workflow_to_loaded(workflow)
        {:cont, {:ok, Map.put(workflows, Map.fetch!(project, :id), loaded)}}
    end
  end

  defp default_project_id(workflows, default_project) do
    case default_project do
      %{id: id} when is_map_key(workflows, id) -> id
      _ -> workflows |> Map.keys() |> List.first()
    end
  end

  defp persistence, do: PersistenceProvider.module()

  defp database_source(workflows, default_project_id) do
    %{
      type: :database,
      default_project_id: default_project_id,
      project_ids: Map.keys(workflows)
    }
  end

  defp setup_required_state do
    %State{
      workflows: %{},
      default_project_id: nil,
      source: %{type: :setup_required},
      generation: 0,
      refresh: nil
    }
  end

  defp error_state(reason) do
    %State{
      workflows: %{},
      default_project_id: nil,
      source: %{type: :error, reason: normalize_current_error(reason)},
      generation: 0,
      refresh: nil
    }
  end

  defp log_reload_failure(mode, kind, reason) do
    Logger.error(
      "Workflow refresh failed action=retain_last_known_good mode=#{mode} kind=#{kind} " <>
        "reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}"
    )
  end

  defp publish(%State{} = state) do
    :persistent_term.put(@snapshot_key, %{
      workflows: state.workflows,
      default_project_id: state.default_project_id,
      source: state.source,
      generation: state.generation
    })
  end

  defp published_snapshot do
    :persistent_term.get(@snapshot_key, %{
      workflows: %{},
      default_project_id: nil,
      source: %{type: :error, reason: :repo_unavailable},
      generation: 0
    })
  end

  defp state_payload(%{source: %{type: :error, reason: reason}}),
    do: {:error, normalize_current_error(reason)}

  defp state_payload(%{source: %{type: :setup_required} = source}) do
    workflow =
      Workflow.setup_required_workflow(Application.get_env(:symphony_elixir, :server_port_override))

    {:ok, %{workflow: workflow, source: source}}
  end

  defp state_payload(%{
         workflows: workflows,
         default_project_id: default_id,
         source: source
       }) do
    case Map.get(workflows, default_id) do
      nil -> {:error, :no_active_workflow}
      workflow -> {:ok, %{workflow: workflow, source: source}}
    end
  end

  defp normalize_current_error(:repo_unavailable), do: :repo_unavailable
  defp normalize_current_error({:query_failed, _reason} = error), do: error
  defp normalize_current_error(reason), do: {:query_failed, reason}
end

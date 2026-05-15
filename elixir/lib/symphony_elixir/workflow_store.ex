defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the active database workflow version.
  """

  use GenServer

  alias SymphonyElixir.{PersistenceProvider, Workflow}

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:workflow, :source]
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

  defp current_with_source_payload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:ok, payload} = GenServer.call(__MODULE__, :current_with_source)
        payload

      _ ->
        state_payload(load_state())
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
    case load_database_workflow() do
      {:ok, workflow} ->
        %State{
          workflow: workflow,
          source: database_source(workflow)
        }

      :setup_required ->
        setup_required_state()
    end
  end

  defp load_database_workflow do
    if database_workflow_enabled?(), do: load_database_version_or_setup(), else: :setup_required
  rescue
    _error -> :setup_required
  end

  defp load_database_version_or_setup do
    case persistence().active_workflow_version() do
      nil -> :setup_required
      workflow_version -> {:ok, workflow_to_loaded(workflow_version)}
    end
  end

  defp database_workflow_enabled? do
    Application.get_env(:symphony_elixir, :workflow_source) in [nil, :database, "database"]
  end

  defp persistence, do: PersistenceProvider.module()

  defp workflow_to_loaded(workflow_version), do: persistence().workflow_to_loaded(workflow_version)

  defp setup_required_state do
    workflow = Workflow.setup_required_workflow(Application.get_env(:symphony_elixir, :server_port_override))

    %State{
      workflow: workflow,
      source: %{type: :setup_required}
    }
  end

  defp state_payload(%State{workflow: workflow, source: source}), do: %{workflow: workflow, source: source}

  defp database_source(workflow) when is_map(workflow) do
    %{
      type: :database,
      workflow_version_id: Map.get(workflow, :workflow_version_id)
    }
  end
end

defmodule SymphonyElixir.TestSupport.FakePersistence do
  @moduledoc false

  @name __MODULE__

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> initial_state() end, name: @name)
  end

  def reset!(state \\ initial_state()) do
    ensure_started()
    Agent.update(@name, fn _ -> state end)
  end

  def calls do
    ensure_started()
    Agent.get(@name, & &1.calls)
  end

  def put_user(username, user) do
    ensure_started()
    Agent.update(@name, &put_in(&1.users[username], user))
  end

  def put_events(events) when is_list(events) do
    ensure_started()
    Agent.update(@name, &Map.put(&1, :events, events))
  end

  def put_workflow_versions(versions, active_version \\ nil) when is_list(versions) do
    ensure_started()

    Agent.update(@name, fn state ->
      state
      |> Map.put(:workflow_versions, versions)
      |> Map.put(:active_workflow_version, active_version)
    end)
  end

  def fail_next_import_workflow!(reason) do
    ensure_started()
    Agent.update(@name, &Map.put(&1, :next_import_workflow_error, reason))
  end

  def default_project do
    ensure_started()
    {:ok, %{id: "fake-project-id", name: "Fake Project", slug: "fake"}}
  end

  def import_workflow(project, raw_workflow_md, source) do
    ensure_started()

    version = %{
      id: "fake-workflow-version",
      project_id: project.id,
      version: 1,
      source: source,
      active: true,
      inserted_at: DateTime.utc_now(),
      raw_workflow_md: raw_workflow_md
    }

    Agent.get_and_update(@name, fn state ->
      state = record_call(state, {:import_workflow, project, raw_workflow_md, source})

      case Map.get(state, :next_import_workflow_error) do
        nil ->
          next_state =
            state
            |> Map.put(:active_workflow_version, version)
            |> Map.put(:workflow_versions, [version])

          {{:ok, version}, next_state}

        reason ->
          {{:error, reason}, Map.put(state, :next_import_workflow_error, nil)}
      end
    end)
  end

  def active_workflow_version do
    ensure_started()
    Agent.get(@name, & &1.active_workflow_version)
  end

  def list_projects do
    ensure_started()
    Agent.get(@name, & &1.projects)
  end

  def list_runs(_opts \\ []) do
    ensure_started()
    Agent.get(@name, & &1.runs)
  end

  def list_events(_opts \\ []) do
    ensure_started()
    Agent.get(@name, & &1.events)
  end

  def list_workers(_opts \\ []) do
    ensure_started()
    Agent.get(@name, & &1.workers)
  end

  def list_worker_sessions(_opts \\ []) do
    ensure_started()
    Agent.get(@name, & &1.worker_sessions)
  end

  def list_tasks(_opts \\ []) do
    ensure_started()
    Agent.get(@name, & &1.tasks)
  end

  def list_task_leases(_opts \\ []) do
    ensure_started()
    Agent.get(@name, & &1.task_leases)
  end

  def list_workflow_versions do
    ensure_started()
    Agent.get(@name, & &1.workflow_versions)
  end

  def list_tracker_configs do
    []
  end

  def export_workflow(%{raw_workflow_md: raw}), do: raw

  def activate_workflow_version(version) do
    ensure_started()
    Agent.update(@name, fn state -> state |> record_call({:activate_workflow_version, version}) |> Map.put(:active_workflow_version, version) end)
    {:ok, version}
  end

  def cancel_task(id, reason \\ "cancelled") do
    ensure_started()
    task = %{id: id, status: "cancelled", payload: %{"reason" => reason}}
    Agent.update(@name, &record_call(&1, {:cancel_task, id, reason}))
    {:ok, task}
  end

  def requeue_task(id) do
    ensure_started()
    task = %{id: id, status: "queued"}
    Agent.update(@name, &record_call(&1, {:requeue_task, id}))
    {:ok, task}
  end

  def repo_available?, do: false

  def get_run(_id), do: nil

  def get_user(username) do
    ensure_started()
    Agent.get(@name, fn state -> Map.get(state.users, username) end)
  end

  def workflow_to_loaded(version) do
    {:ok, workflow} = SymphonyElixir.Workflow.parse_content(version.raw_workflow_md)

    workflow
    |> Map.put(:workflow_version_id, version.id)
    |> Map.put(:project_id, version.project_id)
  end

  def ensure_workflow_seeded_from_file(path) do
    with {:ok, project} <- default_project(),
         {:ok, raw} <- File.read(path) do
      import_workflow(project, raw, "file")
    end
  end

  def worker_heartbeat_interval_seconds, do: 10

  def worker_lease_duration_seconds, do: 60

  def worker_protocol_version, do: "worker-api-v1"

  def valid_worker_registration_token?(token) do
    :symphony_elixir
    |> Application.get_env(:worker_api, [])
    |> Keyword.get(:registration_token)
    |> then(&(&1 == token))
  end

  def register_worker(attrs) do
    ensure_started()
    now = DateTime.utc_now()
    worker_id = "fake-worker-#{System.unique_integer([:positive])}"
    session_id = "fake-session-#{System.unique_integer([:positive])}"

    worker = %{
      id: worker_id,
      name: Map.get(attrs, "worker_name", worker_id),
      status: "online",
      labels: Map.get(attrs, "labels", []),
      last_seen_at: now
    }

    session = %{
      id: session_id,
      worker_id: worker_id,
      status: "online",
      last_heartbeat_at: now
    }

    Agent.update(@name, fn state ->
      state
      |> record_call({:register_worker, attrs})
      |> update_in([:workers], &[worker | &1])
      |> update_in([:worker_sessions], &[session | &1])
    end)

    {:ok, %{worker: worker, session: session}}
  end

  def claim_task(worker_id, session_id, params) do
    ensure_started()
    Agent.update(@name, &record_call(&1, {:claim_task, worker_id, session_id, params}))
    {:ok, nil}
  end

  def heartbeat(worker_id, session_id, params) do
    ensure_started()
    Agent.update(@name, &record_call(&1, {:heartbeat, worker_id, session_id, params}))
    {:ok, %{ok: true, lease_renewals: []}}
  end

  def record_worker_task_event(worker_id, session_id, task_id, event_type, payload) do
    ensure_started()
    event = %{id: "fake-event-#{System.unique_integer([:positive])}"}
    Agent.update(@name, &record_call(&1, {:record_worker_task_event, worker_id, session_id, task_id, event_type, payload}))
    {:ok, event}
  end

  defp initial_state do
    %{
      calls: [],
      projects: [%{id: "fake-project-id", name: "Fake Project", slug: "fake", enabled: true}],
      runs: [],
      events: [],
      workers: [],
      worker_sessions: [],
      tasks: [],
      task_leases: [],
      workflow_versions: [],
      active_workflow_version: nil,
      next_import_workflow_error: nil,
      users: %{}
    }
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil -> start_link()
      _pid -> :ok
    end
  end

  defp record_call(state, call), do: update_in(state.calls, &[call | &1])
end

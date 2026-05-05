defmodule SymphonyElixir.Persistence do
  @moduledoc """
  Persistence context for local Symphony configuration and runtime history.
  """

  import Ecto.Query

  alias SymphonyElixir.Config.Schema, as: ConfigSchema
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Workflow

  alias SymphonyElixir.Persistence.{
    AgentTurn,
    EventRecord,
    IssueRecord,
    Project,
    RunRecord,
    TaskLease,
    TaskRecord,
    TrackerConfig,
    User,
    Worker,
    WorkerSession,
    WorkflowVersion,
    WorkspaceRecord
  }

  @default_project_slug "default"
  @worker_protocol_version "worker-api-v1"
  @worker_heartbeat_interval_seconds 10
  @worker_lease_duration_seconds 60

  @spec repo_available?() :: boolean()
  def repo_available?, do: Process.whereis(Repo) != nil

  @spec default_project() :: {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :repo_unavailable}
  def default_project do
    if repo_available?() do
      case Repo.get_by(Project, slug: @default_project_slug) do
        nil ->
          %Project{}
          |> Project.changeset(%{name: "Default", slug: @default_project_slug, enabled: true})
          |> Repo.insert()

        project ->
          {:ok, project}
      end
    else
      {:error, :repo_unavailable}
    end
  rescue
    _error -> {:error, :repo_unavailable}
  end

  @spec list_projects() :: [Project.t()]
  def list_projects do
    if repo_available?(), do: Repo.all(from(p in Project, order_by: [asc: p.name])), else: []
  end

  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :repo_unavailable}
  def create_project(attrs) do
    if repo_available?(), do: %Project{} |> Project.changeset(attrs) |> Repo.insert(), else: {:error, :repo_unavailable}
  end

  @spec import_workflow(Project.t(), String.t(), String.t()) ::
          {:ok, WorkflowVersion.t()} | {:error, term()}
  def import_workflow(%Project{} = project, raw_workflow_md, source \\ "import") when is_binary(raw_workflow_md) do
    with {:ok, loaded} <- Workflow.parse_content(raw_workflow_md),
         {:ok, _settings} <- ConfigSchema.parse(loaded.config) do
      create_workflow_version(project, %{
        raw_workflow_md: raw_workflow_md,
        yaml_config: loaded.config,
        prompt_body: loaded.prompt,
        source: source,
        active: true
      })
    end
  end

  @spec ensure_workflow_seeded_from_file(Path.t()) :: {:ok, WorkflowVersion.t()} | {:error, term()}
  def ensure_workflow_seeded_from_file(path) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, project} <- default_project(),
         nil <- active_workflow_version(project) do
      path
      |> File.read()
      |> case do
        {:ok, raw} -> import_workflow(project, raw, "file")
        {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
      end
    else
      %WorkflowVersion{} = version -> {:ok, version}
      {:error, reason} -> {:error, reason}
      false -> {:error, :repo_unavailable}
    end
  end

  @spec active_workflow_version() :: WorkflowVersion.t() | nil
  def active_workflow_version, do: active_workflow_version(nil)

  @spec active_workflow_version(Project.t() | nil) :: WorkflowVersion.t() | nil
  def active_workflow_version(nil) do
    case default_project() do
      {:ok, project} -> active_workflow_version(project)
      _ -> nil
    end
  end

  def active_workflow_version(%Project{id: project_id}) do
    if repo_available?() do
      Repo.one(
        from(w in WorkflowVersion,
          where: w.project_id == ^project_id and w.active == true,
          where: ^test_workflow_source_allowed?() or w.source != "test",
          order_by: [desc: w.version],
          limit: 1
        )
      )
    end
  rescue
    _error -> nil
  end

  @spec workflow_to_loaded(WorkflowVersion.t()) :: Workflow.loaded_workflow()
  def workflow_to_loaded(%WorkflowVersion{} = version) do
    %{
      config: version.yaml_config || %{},
      prompt: version.prompt_body || "",
      prompt_template: version.prompt_body || "",
      workflow_version_id: version.id,
      project_id: version.project_id
    }
  end

  @spec export_workflow(WorkflowVersion.t()) :: String.t()
  def export_workflow(%WorkflowVersion{raw_workflow_md: raw}) when is_binary(raw) and raw != "", do: raw
  def export_workflow(%WorkflowVersion{} = version), do: Workflow.to_markdown(version.yaml_config || %{}, version.prompt_body || "")

  @spec activate_workflow_version(WorkflowVersion.t()) :: {:ok, WorkflowVersion.t()} | {:error, term()}
  def activate_workflow_version(%WorkflowVersion{source: "test"} = version) do
    if test_workflow_source_allowed?() do
      activate_workflow_version!(version)
    else
      {:error, :test_workflow_source_not_allowed}
    end
  end

  def activate_workflow_version(%WorkflowVersion{} = version) do
    activate_workflow_version!(version)
  end

  defp activate_workflow_version!(%WorkflowVersion{} = version) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(w in WorkflowVersion, where: w.project_id == ^version.project_id),
        set: [active: false]
      )

      version
      |> WorkflowVersion.changeset(%{active: true})
      |> Repo.update!()
    end)
  end

  defp create_workflow_version(%Project{} = project, attrs) do
    next_version =
      Repo.one(
        from(w in WorkflowVersion,
          where: w.project_id == ^project.id,
          select: max(w.version)
        )
      )
      |> case do
        nil -> 1
        version -> version + 1
      end

    Repo.transaction(fn ->
      if Map.get(attrs, :active) || Map.get(attrs, "active") do
        Repo.update_all(from(w in WorkflowVersion, where: w.project_id == ^project.id), set: [active: false])
      end

      %WorkflowVersion{}
      |> WorkflowVersion.changeset(Map.merge(attrs, %{project_id: project.id, version: next_version}))
      |> Repo.insert!()
    end)
  end

  defp test_workflow_source_allowed? do
    Application.get_env(:symphony_elixir, :allow_test_workflow_source, false) == true
  end

  @spec list_workflow_versions() :: [WorkflowVersion.t()]
  def list_workflow_versions, do: list_workflow_versions(nil)

  @spec list_workflow_versions(Project.t() | nil) :: [WorkflowVersion.t()]
  def list_workflow_versions(nil) do
    case default_project() do
      {:ok, project} -> list_workflow_versions(project)
      _ -> []
    end
  end

  def list_workflow_versions(%Project{id: project_id}) do
    if repo_available?() do
      Repo.all(from(w in WorkflowVersion, where: w.project_id == ^project_id, order_by: [desc: w.version]))
    else
      []
    end
  rescue
    _error -> []
  end

  @spec upsert_issue(map()) :: {:ok, IssueRecord.t()} | {:error, term()}
  def upsert_issue(attrs) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, project} <- default_project() do
      attrs = Map.put_new(attrs, :project_id, project.id)
      identifier = Map.fetch!(attrs, :identifier)
      existing = Repo.get_by(IssueRecord, project_id: attrs.project_id, identifier: identifier)
      (existing || %IssueRecord{}) |> IssueRecord.changeset(attrs) |> Repo.insert_or_update()
    end
  end

  @spec create_run(map()) :: {:ok, RunRecord.t()} | {:error, term()}
  def create_run(attrs) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, project} <- default_project() do
      attrs =
        attrs
        |> Map.put_new(:project_id, project.id)
        |> Map.put_new(:status, "running")
        |> Map.put_new(:started_at, DateTime.utc_now())

      %RunRecord{} |> RunRecord.changeset(attrs) |> Repo.insert()
    end
  end

  @spec update_run(RunRecord.t(), map()) :: {:ok, RunRecord.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%RunRecord{} = run, attrs), do: run |> RunRecord.changeset(attrs) |> Repo.update()

  @spec get_run(String.t()) :: RunRecord.t() | nil
  def get_run(id) when is_binary(id) do
    if repo_available?(), do: Repo.get(RunRecord, id)
  end

  @spec record_event(map()) :: {:ok, EventRecord.t()} | {:error, term()}
  def record_event(attrs) do
    if repo_available?() do
      attrs = Map.put_new(attrs, :occurred_at, DateTime.utc_now())
      %EventRecord{} |> EventRecord.changeset(attrs) |> Repo.insert()
    else
      {:error, :repo_unavailable}
    end
  end

  @spec record_agent_turn(map()) :: {:ok, AgentTurn.t()} | {:error, term()}
  def record_agent_turn(attrs) do
    if repo_available?(), do: %AgentTurn{} |> AgentTurn.changeset(attrs) |> Repo.insert(), else: {:error, :repo_unavailable}
  end

  @spec record_workspace(map()) :: {:ok, WorkspaceRecord.t()} | {:error, term()}
  def record_workspace(attrs) do
    if repo_available?() do
      attrs = Map.put_new(attrs, :created_at, DateTime.utc_now())
      %WorkspaceRecord{} |> WorkspaceRecord.changeset(attrs) |> Repo.insert()
    else
      {:error, :repo_unavailable}
    end
  end

  @spec list_runs(keyword()) :: [RunRecord.t()]
  def list_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(r in RunRecord, order_by: [desc: r.inserted_at], limit: ^limit))
    else
      []
    end
  end

  @spec list_events(keyword()) :: [EventRecord.t()]
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(e in EventRecord, order_by: [desc: e.occurred_at], limit: ^limit))
    else
      []
    end
  end

  @spec get_user(String.t()) :: User.t() | nil
  def get_user(username) when is_binary(username) do
    if repo_available?(), do: Repo.get_by(User, username: username)
  end

  @spec upsert_user(map()) :: {:ok, User.t()} | {:error, term()}
  def upsert_user(attrs) do
    if repo_available?() do
      existing = attrs |> Map.get(:username) |> get_user()
      (existing || %User{}) |> User.changeset(attrs) |> Repo.insert_or_update()
    else
      {:error, :repo_unavailable}
    end
  end

  @spec list_tracker_configs() :: [TrackerConfig.t()]
  def list_tracker_configs do
    if repo_available?(), do: Repo.all(from(t in TrackerConfig, order_by: [asc: t.inserted_at])), else: []
  end

  @spec worker_protocol_version() :: String.t()
  def worker_protocol_version, do: @worker_protocol_version

  @spec worker_heartbeat_interval_seconds() :: pos_integer()
  def worker_heartbeat_interval_seconds, do: worker_api_config(:heartbeat_interval_seconds, @worker_heartbeat_interval_seconds)

  @spec worker_lease_duration_seconds() :: pos_integer()
  def worker_lease_duration_seconds, do: worker_api_config(:lease_duration_seconds, @worker_lease_duration_seconds)

  @spec worker_registration_token() :: String.t() | nil
  def worker_registration_token do
    worker_api_config(:registration_token, nil) || System.get_env("SYMPHONY_WORKER_REGISTRATION_TOKEN")
  end

  @spec valid_worker_registration_token?(String.t() | nil) :: boolean()
  def valid_worker_registration_token?(token) when is_binary(token) do
    configured = worker_registration_token()
    is_binary(configured) and configured != "" and Plug.Crypto.secure_compare(configured, token)
  end

  def valid_worker_registration_token?(_), do: false

  @spec register_worker(map()) :: {:ok, %{worker: Worker.t(), session: WorkerSession.t()}} | {:error, term()}
  def register_worker(attrs) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         :ok <- validate_worker_protocol(map_get(attrs, "protocol_version", :protocol_version)) do
      Repo.transaction(fn -> register_worker!(attrs) end)
    end
  end

  @spec list_workers(keyword()) :: [Worker.t()]
  def list_workers(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(w in Worker, order_by: [asc: w.name], limit: ^limit))
    else
      []
    end
  end

  @spec list_worker_sessions(keyword()) :: [WorkerSession.t()]
  def list_worker_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(s in WorkerSession, order_by: [desc: s.inserted_at], limit: ^limit))
    else
      []
    end
  end

  @spec enqueue_task(map()) :: {:ok, TaskRecord.t()} | {:error, term()}
  def enqueue_task(attrs) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, project} <- default_project() do
      attrs =
        attrs
        |> Map.put_new(:project_id, project.id)
        |> Map.put_new(:status, "queued")
        |> Map.put_new(:priority, 0)
        |> Map.put_new(:execution_mode, "worker")
        |> Map.put_new(:required_capabilities, %{})
        |> Map.put_new(:payload, %{})
        |> Map.put_new(:queued_at, DateTime.utc_now())

      %TaskRecord{} |> TaskRecord.changeset(attrs) |> Repo.insert()
    end
  end

  @spec list_tasks(keyword()) :: [TaskRecord.t()]
  def list_tasks(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(t in TaskRecord, order_by: [desc: t.inserted_at], limit: ^limit))
    else
      []
    end
  end

  @spec list_task_leases(keyword()) :: [TaskLease.t()]
  def list_task_leases(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(l in TaskLease, order_by: [desc: l.inserted_at], limit: ^limit))
    else
      []
    end
  end

  @spec claim_task(String.t(), String.t(), map()) ::
          {:ok, nil | %{task: TaskRecord.t(), lease: TaskLease.t()}} | {:error, term()}
  def claim_task(worker_id, session_id, attrs \\ %{}) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, worker, session} <- active_worker_session(worker_id, session_id) do
      claim_task_for_session(worker, session, attrs)
    end
  rescue
    Ecto.ConstraintError -> {:error, :lease_conflict}
    MatchError -> {:error, :lease_conflict}
  end

  @spec heartbeat(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def heartbeat(worker_id, session_id, attrs \\ %{}) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, worker, session} <- active_worker_session(worker_id, session_id) do
      Repo.transaction(fn -> heartbeat!(worker, session, attrs) end)
    end
  end

  @spec expire_stale_worker_state(keyword()) :: {non_neg_integer(), non_neg_integer()}
  def expire_stale_worker_state(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    heartbeat_timeout_seconds = Keyword.get(opts, :heartbeat_timeout_seconds, worker_heartbeat_interval_seconds() * 3)
    heartbeat_cutoff = DateTime.add(now, -heartbeat_timeout_seconds, :second)

    if repo_available?() do
      {offline_sessions, _} =
        Repo.update_all(
          from(s in WorkerSession,
            where: s.status == "online" and s.last_heartbeat_at < ^heartbeat_cutoff
          ),
          set: [status: "offline", disconnected_at: now, updated_at: now]
        )

      {expired_leases, leases} =
        Repo.update_all(
          from(l in TaskLease, where: l.status == "active" and l.expires_at < ^now, select: l.task_id),
          set: [status: "expired", released_at: now, updated_at: now]
        )

      if leases != [] do
        Repo.update_all(
          from(t in TaskRecord, where: t.id in ^leases and t.status in ["leased", "running"]),
          set: [status: "queued", updated_at: now]
        )
      end

      {offline_sessions, expired_leases}
    else
      {0, 0}
    end
  end

  @spec cancel_task(String.t(), String.t()) :: {:ok, TaskRecord.t()} | {:error, term()}
  def cancel_task(task_id, reason \\ "operator_requested") do
    if repo_available?() do
      case Repo.get(TaskRecord, task_id) do
        nil ->
          {:error, :task_not_found}

        task ->
          payload = Map.put(task.payload || %{}, "cancel_reason", reason)
          task |> TaskRecord.changeset(%{status: "cancelled", payload: payload, finished_at: DateTime.utc_now()}) |> Repo.update()
      end
    else
      {:error, :repo_unavailable}
    end
  end

  @spec requeue_task(String.t()) :: {:ok, TaskRecord.t()} | {:error, term()}
  def requeue_task(task_id) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         %TaskRecord{} = task <- Repo.get(TaskRecord, task_id) || {:error, :task_not_found} do
      Repo.transaction(fn -> requeue_task!(task) end)
    end
  end

  @spec record_worker_task_event(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, EventRecord.t()} | {:error, term()}
  def record_worker_task_event(worker_id, session_id, task_id, event_type, payload \\ %{}) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, worker, session} <- active_worker_session(worker_id, session_id),
         %TaskRecord{} = task <- Repo.get(TaskRecord, task_id) || {:error, :task_not_found},
         %TaskLease{} = lease <- active_lease_for(task.id, worker.id, session.id) || {:error, :lease_not_active},
         :ok <- reject_expired_lease(lease) do
      Repo.transaction(fn ->
        transition_task_from_event!(task, event_type)

        %EventRecord{}
        |> EventRecord.changeset(%{
          project_id: task.project_id,
          run_id: task.run_id,
          issue_identifier: task.issue_identifier,
          event_type: event_type,
          payload: Map.merge(payload || %{}, %{"worker_id" => worker.id, "task_id" => task.id, "lease_id" => lease.id}),
          occurred_at: DateTime.utc_now()
        })
        |> Repo.insert!()
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp worker_api_config(key, default) do
    :symphony_elixir
    |> Application.get_env(:worker_api, [])
    |> Keyword.get(key, default)
  end

  defp validate_worker_protocol(@worker_protocol_version), do: :ok
  defp validate_worker_protocol(_), do: {:error, :unsupported_protocol_version}

  defp register_worker!(attrs) do
    now = DateTime.utc_now()
    name = map_get(attrs, "worker_name", :worker_name) || map_get(attrs, "name", :name)
    labels = normalize_labels(map_get(attrs, "labels", :labels))
    capabilities = map_get(attrs, "capabilities", :capabilities) || %{}
    worker = upsert_worker!(name, labels, capabilities, now)
    session = create_worker_session!(worker, attrs, now)

    %{worker: worker, session: session}
  end

  defp upsert_worker!(name, labels, capabilities, now) do
    (Repo.get_by(Worker, name: name) || %Worker{})
    |> Worker.changeset(%{
      name: name,
      status: "online",
      labels: %{"values" => labels},
      capabilities: capabilities,
      credential_ref: credential_ref(name),
      last_seen_at: now
    })
    |> Repo.insert_or_update!()
  end

  defp create_worker_session!(worker, attrs, now) do
    %WorkerSession{}
    |> WorkerSession.changeset(%{
      worker_id: worker.id,
      protocol_version: @worker_protocol_version,
      worker_version: map_get(attrs, "worker_version", :worker_version),
      instance_id: map_get(attrs, "instance_id", :instance_id),
      connected_at: now,
      last_heartbeat_at: now,
      status: "online"
    })
    |> Repo.insert!()
  end

  defp claim_task_for_session(worker, session, attrs) do
    available_slots = map_get(attrs, "available_slots", :available_slots) || 1
    capabilities = map_get(attrs, "capabilities", :capabilities) || worker.capabilities || %{}

    labels =
      attrs
      |> map_get("labels", :labels)
      |> Kernel.||(Map.get(capabilities, "labels"))
      |> Kernel.||(worker.labels)
      |> normalize_labels()

    if available_slots < 1 do
      {:ok, nil}
    else
      Repo.transaction(fn -> claim_matching_task!(worker, session, labels, capabilities) end)
    end
  end

  defp claim_matching_task!(worker, session, labels, capabilities) do
    case next_matching_task(labels, capabilities) do
      nil -> nil
      task -> lease_task!(task, worker, session)
    end
  end

  defp next_matching_task(labels, capabilities) do
    TaskRecord
    |> where([t], t.status == "queued")
    |> order_by([t], desc: t.priority, asc: t.queued_at)
    |> Repo.all()
    |> Enum.find(&capability_match?(&1.required_capabilities, labels, capabilities))
  end

  defp lease_task!(task, worker, session) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, worker_lease_duration_seconds(), :second)
    attempt = next_lease_attempt(task.id)

    {1, _rows} =
      Repo.update_all(
        from(t in TaskRecord, where: t.id == ^task.id and t.status == "queued"),
        set: [status: "leased", started_at: now, updated_at: now]
      )

    lease =
      %TaskLease{}
      |> TaskLease.changeset(%{
        task_id: task.id,
        worker_id: worker.id,
        worker_session_id: session.id,
        status: "active",
        attempt: attempt,
        acquired_at: now,
        expires_at: expires_at
      })
      |> Repo.insert!()

    %{task: Repo.get!(TaskRecord, task.id), lease: lease}
  end

  defp heartbeat!(worker, session, attrs) do
    now = DateTime.utc_now()
    lease_ids = map_get(attrs, "active_leases", :active_leases) || []
    expires_at = DateTime.add(now, worker_lease_duration_seconds(), :second)

    worker |> Worker.changeset(%{status: "online", last_seen_at: now}) |> Repo.update!()
    session |> WorkerSession.changeset(%{status: "online", last_heartbeat_at: now}) |> Repo.update!()

    %{
      ok: true,
      server_time: now,
      lease_renewals: renew_leases(worker.id, session.id, lease_ids, expires_at),
      commands: cancellation_commands(worker.id, session.id)
    }
  end

  defp renew_leases(worker_id, session_id, lease_ids, expires_at) do
    TaskLease
    |> where([l], l.worker_id == ^worker_id and l.worker_session_id == ^session_id and l.status == "active")
    |> where([l], l.id in ^lease_ids)
    |> Repo.all()
    |> Enum.map(fn lease ->
      lease = lease |> TaskLease.changeset(%{expires_at: expires_at}) |> Repo.update!()
      %{lease_id: lease.id, lease_expires_at: lease.expires_at}
    end)
  end

  defp requeue_task!(task) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(l in TaskLease, where: l.task_id == ^task.id and l.status == "active"),
      set: [status: "cancelled", released_at: now, updated_at: now]
    )

    task
    |> TaskRecord.changeset(%{status: "queued", started_at: nil, finished_at: nil, queued_at: now})
    |> Repo.update!()
  end

  defp active_worker_session(worker_id, session_id) do
    case {Repo.get(Worker, worker_id), Repo.get(WorkerSession, session_id)} do
      {%Worker{} = worker, %WorkerSession{worker_id: ^worker_id, status: "online"} = session} ->
        {:ok, worker, session}

      _ ->
        {:error, :worker_session_not_found}
    end
  end

  defp normalize_labels(%{"values" => labels}), do: normalize_labels(labels)
  defp normalize_labels(labels) when is_list(labels), do: Enum.map(labels, &to_string/1)
  defp normalize_labels(_), do: []

  defp capability_match?(required, labels, capabilities) do
    required_labels = normalize_labels(Map.get(required || %{}, "labels", Map.get(required || %{}, :labels, [])))
    required_sandbox = normalize_labels(Map.get(required || %{}, "sandbox", Map.get(required || %{}, :sandbox, [])))
    worker_sandbox = normalize_labels(Map.get(capabilities || %{}, "sandbox", Map.get(capabilities || %{}, :sandbox, [])))

    Enum.all?(required_labels, &(&1 in labels)) and Enum.all?(required_sandbox, &(&1 in worker_sandbox))
  end

  defp next_lease_attempt(task_id) do
    Repo.one(from(l in TaskLease, where: l.task_id == ^task_id, select: count(l.id))) + 1
  end

  defp cancellation_commands(worker_id, session_id) do
    TaskLease
    |> join(:inner, [l], t in TaskRecord, on: t.id == l.task_id)
    |> where([l, t], l.worker_id == ^worker_id and l.worker_session_id == ^session_id and l.status == "active")
    |> where([_l, t], t.status == "cancelled")
    |> select([_l, t], %{type: "cancel_task", task_id: t.id, reason: fragment("json_extract(?, '$.cancel_reason')", t.payload)})
    |> Repo.all()
  end

  defp active_lease_for(task_id, worker_id, session_id) do
    Repo.one(
      from(l in TaskLease,
        where:
          l.task_id == ^task_id and l.worker_id == ^worker_id and l.worker_session_id == ^session_id and
            l.status == "active",
        limit: 1
      )
    )
  end

  defp reject_expired_lease(%TaskLease{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt, do: {:error, :lease_expired}, else: :ok
  end

  defp transition_task_from_event!(task, event_type) do
    attrs =
      case event_type do
        "task.accepted" -> %{status: "running", started_at: task.started_at || DateTime.utc_now()}
        "task.completed" -> %{status: "completed", finished_at: DateTime.utc_now()}
        "task.failed" -> %{status: "failed", finished_at: DateTime.utc_now()}
        "task.cancelled" -> %{status: "cancelled", finished_at: DateTime.utc_now()}
        _ -> %{}
      end

    if attrs != %{} do
      updated_task = task |> TaskRecord.changeset(attrs) |> Repo.update!()
      transition_run_from_task_event!(updated_task, event_type)
      release_lease_for_terminal_event!(updated_task, event_type)
    end
  end

  defp transition_run_from_task_event!(%TaskRecord{run_id: nil}, _event_type), do: :ok

  defp transition_run_from_task_event!(%TaskRecord{} = task, event_type) do
    attrs =
      case event_type do
        "task.accepted" -> %{status: "running"}
        "task.completed" -> %{status: "completed", finished_at: DateTime.utc_now()}
        "task.failed" -> %{status: "failed", finished_at: DateTime.utc_now()}
        "task.cancelled" -> %{status: "cancelled", finished_at: DateTime.utc_now()}
        _ -> %{}
      end

    if attrs == %{} do
      :ok
    else
      case Repo.get(RunRecord, task.run_id) do
        %RunRecord{} = run -> run |> RunRecord.changeset(attrs) |> Repo.update!()
        _ -> :ok
      end
    end
  end

  defp release_lease_for_terminal_event!(%TaskRecord{} = task, event_type)
       when event_type in ["task.completed", "task.failed", "task.cancelled"] do
    Repo.update_all(
      from(l in TaskLease, where: l.task_id == ^task.id and l.status == "active"),
      set: [status: "released", released_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )
  end

  defp release_lease_for_terminal_event!(_task, _event_type) do
    :ok
  end

  defp credential_ref(name) when is_binary(name) do
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
    "worker:#{digest}"
  end

  defp map_get(map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end
end

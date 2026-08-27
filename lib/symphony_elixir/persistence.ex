defmodule SymphonyElixir.Persistence do
  @moduledoc """
  PostgreSQL persistence context for Symphony configuration and runtime history.
  """

  import Ecto.Query

  alias SymphonyElixir.{PersistenceProvider, Repo, RunLifecycle, Workflow}
  alias SymphonyElixir.WorkflowStore, as: RuntimeWorkflowStore

  alias SymphonyElixir.Persistence.{
    EventRecord,
    IssueRecord,
    Project,
    RunRecord,
    TaskRecord,
    User,
    WorkerQueue,
    WorkflowStore,
    WorkflowVersion,
    WorkspaceRecord
  }

  @spec repo_available?() :: boolean()
  def repo_available?, do: Process.whereis(Repo) != nil

  defp required_project_id(attrs) do
    case Map.get(attrs, :project_id) do
      project_id when is_binary(project_id) and project_id != "" -> {:ok, project_id}
      _missing -> {:error, :project_id_required}
    end
  end

  @type read_error :: :repo_unavailable | {:query_failed, term()}

  @spec default_project() ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :not_found | :repo_unavailable}
  defdelegate default_project(), to: WorkflowStore

  @spec list_projects() :: [Project.t()] | {:error, read_error()}
  def list_projects, do: read(fn -> WorkflowStore.list_projects() end)

  @spec create_project(map()) ::
          {:ok, Project.t()}
          | {:error,
             Ecto.Changeset.t()
             | :repo_unavailable
             | {:runtime_publication_failed, Project.t(), term()}}
  def create_project(attrs) do
    attrs
    |> WorkflowStore.create_project()
    |> publish_runtime_snapshot()
  end

  @spec update_project(Project.t() | String.t(), map()) ::
          {:ok, Project.t()}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :repo_unavailable
             | {:runtime_publication_failed, Project.t(), term()}}
  def update_project(project_or_id, attrs) do
    project_or_id
    |> WorkflowStore.update_project(attrs)
    |> publish_runtime_snapshot()
  end

  @spec delete_project(Project.t() | String.t()) ::
          {:ok, Project.t()}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :repo_unavailable
             | {:runtime_publication_failed, Project.t(), term()}}
  def delete_project(%Project{id: id}), do: delete_project(id)

  def delete_project(id) when is_binary(id) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         %Project{} = project <- Repo.get(Project, id) || {:error, :not_found} do
      Repo.transaction(fn -> delete_project!(project) end)
      |> publish_runtime_snapshot()
    end
  end

  @spec import_workflow(Project.t(), String.t(), String.t()) ::
          {:ok, WorkflowVersion.t()}
          | {:error, term() | {:runtime_publication_failed, WorkflowVersion.t(), term()}}
  def import_workflow(project, raw_workflow_md, source \\ "import") do
    project
    |> WorkflowStore.import_workflow(raw_workflow_md, source)
    |> publish_runtime_snapshot()
  end

  @spec active_workflow_version() :: WorkflowVersion.t() | nil
  defdelegate active_workflow_version(), to: WorkflowStore

  @spec active_workflow_version(Project.t() | nil) :: WorkflowVersion.t() | nil
  defdelegate active_workflow_version(project), to: WorkflowStore

  @spec workflow_to_loaded(WorkflowVersion.t()) :: Workflow.loaded_workflow()
  defdelegate workflow_to_loaded(version), to: WorkflowStore

  @spec export_workflow(WorkflowVersion.t()) :: String.t()
  defdelegate export_workflow(version), to: WorkflowStore

  @spec activate_workflow_version(WorkflowVersion.t()) :: {:ok, WorkflowVersion.t()} | {:error, term()}
  def activate_workflow_version(version) do
    version
    |> WorkflowStore.activate_workflow_version()
    |> publish_runtime_snapshot()
  end

  @spec list_workflow_versions() :: [WorkflowVersion.t()]
  defdelegate list_workflow_versions(), to: WorkflowStore

  @spec list_workflow_versions(Project.t() | nil) :: [WorkflowVersion.t()]
  defdelegate list_workflow_versions(project), to: WorkflowStore

  defp delete_project!(project) do
    Repo.update_all(from(run in RunRecord, where: run.project_id == ^project.id), set: [project_id: nil])
    Repo.update_all(from(issue in IssueRecord, where: issue.project_id == ^project.id), set: [project_id: nil])
    Repo.update_all(from(task in TaskRecord, where: task.project_id == ^project.id), set: [project_id: nil])

    case Repo.delete(project) do
      {:ok, deleted_project} -> deleted_project
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec upsert_issue(map()) :: {:ok, IssueRecord.t()} | {:error, term()}
  def upsert_issue(attrs) do
    with {:ok, _project_id} <- required_project_id(attrs),
         true <- repo_available?() || {:error, :repo_unavailable} do
      identifier = Map.fetch!(attrs, :identifier)
      existing = Repo.get_by(IssueRecord, project_id: attrs.project_id, identifier: identifier)
      (existing || %IssueRecord{}) |> IssueRecord.changeset(attrs) |> Repo.insert_or_update()
    end
  end

  @spec create_run(map()) :: {:ok, RunRecord.t()} | {:error, term()}
  def create_run(attrs) do
    with {:ok, _project_id} <- required_project_id(attrs),
         true <- repo_available?() || {:error, :repo_unavailable} do
      attrs =
        attrs
        |> Map.put_new(:status, "running")
        |> Map.put_new(:started_at, DateTime.utc_now())

      %RunRecord{} |> RunRecord.changeset(attrs) |> Repo.insert()
    end
  end

  @spec update_run(RunRecord.t(), map()) :: {:ok, RunRecord.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%RunRecord{} = run, attrs), do: run |> RunRecord.changeset(attrs) |> Repo.update()

  @spec finish_run(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, RunRecord.t()} | {:error, term()}
  def finish_run(run_id, status, failure_reason \\ nil, opts \\ []) when is_binary(run_id) and is_binary(status) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         %RunRecord{} = run <- Repo.get(RunRecord, run_id) || {:error, :not_found} do
      update_run(run, RunLifecycle.terminal_attrs(status, failure_reason, Keyword.get(opts, :finished_at, DateTime.utc_now())))
    end
  end

  @spec get_run(String.t()) :: RunRecord.t() | nil
  def get_run(id) when is_binary(id) do
    if repo_available?(), do: Repo.get(RunRecord, id)
  end

  @spec get_workflow_version(String.t()) :: WorkflowVersion.t() | nil
  def get_workflow_version(id) when is_binary(id) do
    if repo_available?(), do: Repo.get(WorkflowVersion, id)
  end

  @spec get_issue_by_identifier(String.t()) :: IssueRecord.t() | nil | {:error, read_error()}
  def get_issue_by_identifier(identifier) when is_binary(identifier) do
    read(fn -> Repo.get_by(IssueRecord, identifier: identifier) end)
  end

  @spec list_runs_for_issue(String.t(), keyword()) :: [RunRecord.t()] | {:error, read_error()}
  def list_runs_for_issue(identifier, opts \\ []) when is_binary(identifier) do
    limit = Keyword.get(opts, :limit, 100)

    read(fn ->
      Repo.all(from(r in RunRecord, where: r.issue_identifier == ^identifier, order_by: [desc: r.started_at], limit: ^limit))
    end)
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

  @spec record_workspace(map()) :: {:ok, WorkspaceRecord.t()} | {:error, term()}
  def record_workspace(attrs) do
    if repo_available?() do
      attrs = Map.put_new(attrs, :created_at, DateTime.utc_now())
      %WorkspaceRecord{} |> WorkspaceRecord.changeset(attrs) |> Repo.insert()
    else
      {:error, :repo_unavailable}
    end
  end

  @spec list_runs(keyword()) :: [RunRecord.t()] | {:error, read_error()}
  def list_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    read(fn ->
      RunRecord
      |> run_filters(opts)
      |> order_runs()
      |> limit(^limit)
      |> Repo.all()
    end)
  end

  @spec list_runs_page(keyword()) ::
          %{entries: [RunRecord.t()], has_more?: boolean(), next_cursor: String.t() | nil}
          | {:error, read_error()}
  def list_runs_page(opts \\ []) do
    page_size = opts |> Keyword.get(:page_size, 25) |> max(1)
    cursor = Keyword.get(opts, :cursor)

    read(fn ->
      entries =
        RunRecord
        |> run_filters(opts)
        |> maybe_apply_run_cursor(cursor)
        |> order_runs()
        |> limit(^(page_size + 1))
        |> Repo.all()

      {page_entries, overflow} = Enum.split(entries, page_size)

      %{
        entries: page_entries,
        has_more?: overflow != [],
        next_cursor: next_run_cursor(List.last(page_entries), overflow != [])
      }
    end)
  end

  @spec list_events(keyword()) :: [EventRecord.t()] | {:error, read_error()}
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    read(fn ->
      EventRecord
      |> maybe_filter_event_issue(Keyword.get(opts, :issue_identifier))
      |> maybe_filter_event_run(Keyword.get(opts, :run_id))
      |> maybe_filter_event_type(Keyword.get(opts, :event_type))
      |> maybe_filter_event_project(Keyword.get(opts, :project_id))
      |> order_events(Keyword.get(opts, :order, :desc))
      |> limit(^limit)
      |> Repo.all()
    end)
  end

  defp read(fun) do
    if repo_available?() do
      PersistenceProvider.read(fun)
    else
      {:error, :repo_unavailable}
    end
  end

  defp publish_runtime_snapshot({:ok, persisted} = success) do
    case RuntimeWorkflowStore.force_reload() do
      :ok -> success
      {:error, reason} -> {:error, {:runtime_publication_failed, persisted, reason}}
    end
  end

  defp publish_runtime_snapshot(other), do: other

  defp maybe_filter_event_project(query, project_id) when is_binary(project_id) and project_id != "" do
    where(query, [e], e.project_id == ^project_id)
  end

  defp maybe_filter_event_project(query, _project_id), do: query

  defp run_filters(query, opts) do
    query
    |> maybe_filter_run_status(Keyword.get(opts, :status))
    |> maybe_filter_run_kind(Keyword.get(opts, :kind))
    |> maybe_filter_run_project(Keyword.get(opts, :project_id))
  end

  defp maybe_filter_run_project(query, project_id) when is_binary(project_id) and project_id != "" do
    where(query, [r], r.project_id == ^project_id)
  end

  defp maybe_filter_run_project(query, _project_id), do: query

  defp maybe_filter_run_status(query, status) when is_binary(status) and status != "" do
    where(query, [r], r.status == ^status)
  end

  defp maybe_filter_run_status(query, _status), do: query

  defp maybe_filter_run_kind(query, kind) when is_binary(kind) and kind != "" do
    where(query, [r], r.kind == ^kind)
  end

  defp maybe_filter_run_kind(query, _kind), do: query

  defp maybe_apply_run_cursor(query, nil), do: query
  defp maybe_apply_run_cursor(query, ""), do: query

  defp maybe_apply_run_cursor(query, cursor) when is_binary(cursor) do
    case decode_run_cursor(cursor) do
      {:ok, inserted_at, id} ->
        where(query, [r], r.inserted_at < ^inserted_at or (r.inserted_at == ^inserted_at and r.id < ^id))

      :error ->
        query
    end
  end

  defp order_runs(query), do: order_by(query, [r], desc: r.inserted_at, desc: r.id)

  defp next_run_cursor(_run, false), do: nil
  defp next_run_cursor(nil, _has_more), do: nil

  defp next_run_cursor(run, true) do
    encoded = Jason.encode!(%{"inserted_at" => DateTime.to_iso8601(run.inserted_at), "id" => run.id})
    Base.url_encode64(encoded, padding: false)
  end

  defp decode_run_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"inserted_at" => inserted_at, "id" => id}} <- Jason.decode(json),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(inserted_at),
         true <- is_binary(id) do
      {:ok, datetime, id}
    else
      _ -> :error
    end
  end

  defp order_events(query, :asc), do: order_by(query, [e], asc: e.occurred_at)
  defp order_events(query, "asc"), do: order_by(query, [e], asc: e.occurred_at)
  defp order_events(query, _order), do: order_by(query, [e], desc: e.occurred_at)

  defp maybe_filter_event_issue(query, issue_identifier) when is_binary(issue_identifier) and issue_identifier != "" do
    where(query, [e], e.issue_identifier == ^issue_identifier)
  end

  defp maybe_filter_event_issue(query, _issue_identifier), do: query

  defp maybe_filter_event_run(query, run_id) when is_binary(run_id) and run_id != "" do
    where(query, [e], e.run_id == ^run_id)
  end

  defp maybe_filter_event_run(query, _run_id), do: query

  defp maybe_filter_event_type(query, event_type) when is_binary(event_type) and event_type != "" do
    where(query, [e], e.event_type == ^event_type)
  end

  defp maybe_filter_event_type(query, _event_type), do: query

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

  @spec worker_protocol_version() :: String.t()
  defdelegate worker_protocol_version(), to: WorkerQueue

  @spec worker_heartbeat_interval_seconds() :: pos_integer()
  defdelegate worker_heartbeat_interval_seconds(), to: WorkerQueue

  @spec worker_lease_duration_seconds() :: pos_integer()
  defdelegate worker_lease_duration_seconds(), to: WorkerQueue

  @spec worker_registration_token() :: String.t() | nil
  defdelegate worker_registration_token(), to: WorkerQueue

  @spec valid_worker_registration_token?(String.t() | nil) :: boolean()
  defdelegate valid_worker_registration_token?(token), to: WorkerQueue

  @spec register_worker(map()) :: {:ok, map()} | {:error, term()}
  defdelegate register_worker(attrs), to: WorkerQueue

  @spec list_workers(keyword()) :: list()
  defdelegate list_workers(opts \\ []), to: WorkerQueue

  @spec list_worker_sessions(keyword()) :: list()
  defdelegate list_worker_sessions(opts \\ []), to: WorkerQueue

  @spec enqueue_task(map()) :: {:ok, term()} | {:error, term()}
  defdelegate enqueue_task(attrs), to: WorkerQueue

  @spec list_tasks(keyword()) :: list()
  defdelegate list_tasks(opts \\ []), to: WorkerQueue

  @spec list_task_leases(keyword()) :: list()
  defdelegate list_task_leases(opts \\ []), to: WorkerQueue

  @spec claim_task(String.t(), String.t(), map()) :: {:ok, nil | map()} | {:error, term()}
  defdelegate claim_task(worker_id, session_id, attrs \\ %{}), to: WorkerQueue

  @spec heartbeat(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate heartbeat(worker_id, session_id, attrs \\ %{}), to: WorkerQueue

  @spec expire_stale_worker_state(keyword()) :: {non_neg_integer(), non_neg_integer()}
  defdelegate expire_stale_worker_state(opts \\ []), to: WorkerQueue

  @spec cancel_task(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate cancel_task(task_id, reason \\ "operator_requested"), to: WorkerQueue

  @spec requeue_task(String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate requeue_task(task_id), to: WorkerQueue

  @spec record_worker_task_event(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, EventRecord.t()} | {:error, term()}
  defdelegate record_worker_task_event(worker_id, session_id, task_id, event_type, payload \\ %{}), to: WorkerQueue
end

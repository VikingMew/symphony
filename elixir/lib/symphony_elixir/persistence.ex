defmodule SymphonyElixir.Persistence do
  @moduledoc """
  Persistence context for local Symphony configuration and runtime history.
  """

  import Ecto.Query

  alias SymphonyElixir.Repo
  alias SymphonyElixir.{RunLifecycle, Workflow}

  alias SymphonyElixir.Persistence.{
    AgentTurn,
    EventRecord,
    IssueRecord,
    Project,
    RunRecord,
    TrackerConfig,
    User,
    WorkerQueue,
    WorkflowStore,
    WorkflowVersion,
    WorkspaceRecord
  }

  @spec repo_available?() :: boolean()
  def repo_available?, do: Process.whereis(Repo) != nil

  @spec default_project() :: {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :repo_unavailable}
  defdelegate default_project(), to: WorkflowStore

  @spec list_projects() :: [Project.t()]
  defdelegate list_projects(), to: WorkflowStore

  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :repo_unavailable}
  defdelegate create_project(attrs), to: WorkflowStore

  @spec update_project(Project.t() | String.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :not_found | :repo_unavailable}
  defdelegate update_project(project_or_id, attrs), to: WorkflowStore

  @spec import_workflow(Project.t(), String.t(), String.t()) ::
          {:ok, WorkflowVersion.t()} | {:error, term()}
  defdelegate import_workflow(project, raw_workflow_md, source \\ "import"), to: WorkflowStore

  @spec active_workflow_version() :: WorkflowVersion.t() | nil
  defdelegate active_workflow_version(), to: WorkflowStore

  @spec active_workflow_version(Project.t() | nil) :: WorkflowVersion.t() | nil
  defdelegate active_workflow_version(project), to: WorkflowStore

  @spec workflow_to_loaded(WorkflowVersion.t()) :: Workflow.loaded_workflow()
  defdelegate workflow_to_loaded(version), to: WorkflowStore

  @spec export_workflow(WorkflowVersion.t()) :: String.t()
  defdelegate export_workflow(version), to: WorkflowStore

  @spec activate_workflow_version(WorkflowVersion.t()) :: {:ok, WorkflowVersion.t()} | {:error, term()}
  defdelegate activate_workflow_version(version), to: WorkflowStore

  @spec list_workflow_versions() :: [WorkflowVersion.t()]
  defdelegate list_workflow_versions(), to: WorkflowStore

  @spec list_workflow_versions(Project.t() | nil) :: [WorkflowVersion.t()]
  defdelegate list_workflow_versions(project), to: WorkflowStore

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

  @spec get_issue_by_identifier(String.t()) :: IssueRecord.t() | nil
  def get_issue_by_identifier(identifier) when is_binary(identifier) do
    if repo_available?(), do: Repo.get_by(IssueRecord, identifier: identifier)
  end

  @spec list_runs_for_issue(String.t(), keyword()) :: [RunRecord.t()]
  def list_runs_for_issue(identifier, opts \\ []) when is_binary(identifier) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(r in RunRecord, where: r.issue_identifier == ^identifier, order_by: [desc: r.started_at], limit: ^limit))
    else
      []
    end
  end

  @spec list_agent_turns_for_run(String.t()) :: [AgentTurn.t()]
  def list_agent_turns_for_run(run_id) when is_binary(run_id) do
    if repo_available?() do
      Repo.all(from(t in AgentTurn, where: t.run_id == ^run_id, order_by: [asc: t.turn_index]))
    else
      []
    end
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
      RunRecord
      |> maybe_filter_run_status(Keyword.get(opts, :status))
      |> order_by([r], desc: r.inserted_at)
      |> limit(^limit)
      |> Repo.all()
    else
      []
    end
  end

  @spec list_events(keyword()) :: [EventRecord.t()]
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      EventRecord
      |> maybe_filter_event_issue(Keyword.get(opts, :issue_identifier))
      |> maybe_filter_event_run(Keyword.get(opts, :run_id))
      |> maybe_filter_event_type(Keyword.get(opts, :event_type))
      |> order_events(Keyword.get(opts, :order, :desc))
      |> limit(^limit)
      |> Repo.all()
    else
      []
    end
  end

  defp maybe_filter_run_status(query, status) when is_binary(status) and status != "" do
    where(query, [r], r.status == ^status)
  end

  defp maybe_filter_run_status(query, _status), do: query

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

  @spec list_tracker_configs() :: [TrackerConfig.t()]
  def list_tracker_configs do
    if repo_available?(), do: Repo.all(from(t in TrackerConfig, order_by: [asc: t.inserted_at])), else: []
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

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
    TrackerConfig,
    User,
    WorkflowVersion,
    WorkspaceRecord
  }

  @default_project_slug "default"

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
  def activate_workflow_version(%WorkflowVersion{} = version) do
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
end

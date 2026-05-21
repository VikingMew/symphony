defmodule SymphonyElixir.Persistence.WorkflowStore do
  @moduledoc """
  Project and workflow-version persistence plus runtime project overlays.
  """

  import Ecto.Query

  alias SymphonyElixir.Repo
  alias SymphonyElixir.{Persistence, Workflow}
  alias SymphonyElixir.Persistence.{Project, WorkflowVersion}

  @default_project_slug "default"

  @spec default_project() :: {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :repo_unavailable}
  def default_project do
    if Persistence.repo_available?() do
      case Repo.get_by(Project, slug: @default_project_slug) do
        nil ->
          %Project{}
          |> Project.changeset(%{name: "Default", slug: @default_project_slug, default_branch: "main", enabled: true})
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
    if Persistence.repo_available?(), do: Repo.all(from(p in Project, order_by: [asc: p.name])), else: []
  end

  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :repo_unavailable}
  def create_project(attrs) do
    if Persistence.repo_available?(), do: %Project{} |> Project.changeset(attrs) |> Repo.insert(), else: {:error, :repo_unavailable}
  end

  @spec update_project(Project.t() | String.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :not_found | :repo_unavailable}
  def update_project(%Project{} = project, attrs) do
    if Persistence.repo_available?(), do: project |> Project.changeset(attrs) |> Repo.update(), else: {:error, :repo_unavailable}
  end

  def update_project(id, attrs) when is_binary(id) do
    with true <- Persistence.repo_available?() || {:error, :repo_unavailable},
         %Project{} = project <- Repo.get(Project, id) || {:error, :not_found} do
      update_project(project, attrs)
    end
  end

  @spec import_workflow(Project.t(), String.t(), String.t()) ::
          {:ok, WorkflowVersion.t()} | {:error, term()}
  def import_workflow(%Project{} = project, raw_workflow_md, source \\ "import") when is_binary(raw_workflow_md) do
    with {:ok, loaded} <- Workflow.parse_content(raw_workflow_md) do
      create_workflow_version(project, %{
        raw_workflow_md: raw_workflow_md,
        yaml_config: loaded.config,
        prompt_body: loaded.prompt,
        source: source,
        active: true
      })
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
    if Persistence.repo_available?() do
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
    config =
      version.yaml_config
      |> Kernel.||(%{})
      |> apply_project_runtime_settings(version.project_id)

    %{
      config: config,
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
    if Persistence.repo_available?() do
      Repo.all(from(w in WorkflowVersion, where: w.project_id == ^project_id, order_by: [desc: w.version]))
    else
      []
    end
  rescue
    _error -> []
  end

  defp apply_project_runtime_settings(config, project_id) when is_map(config) do
    case project_for_runtime(project_id) do
      %Project{} = project ->
        config
        |> put_in_path(["tracker", "project_slug"], project.linear_project_slug)
        |> update_project_config(project)

      _ ->
        config
    end
  end

  defp project_for_runtime(project_id) when is_binary(project_id) do
    if Persistence.repo_available?(), do: Repo.get(Project, project_id), else: nil
  rescue
    _error -> nil
  end

  defp project_for_runtime(_project_id) do
    case default_project() do
      {:ok, project} -> project
      _ -> nil
    end
  end

  defp update_project_config(config, %Project{} = project) do
    existing = Map.get(config, "project", %{})

    project_config =
      existing
      |> put_project_value("repository_url", project.repository_url)
      |> put_project_value("default_branch", project.default_branch || "main")
      |> put_project_value("checkout_depth", project.checkout_depth || 1)
      |> put_project_value("source_strategy", project.source_strategy || "clone")
      |> put_project_value("worktree_fetch", project.worktree_fetch != false)
      |> put_project_value("worktree_cleanup", project.worktree_cleanup != false)

    Map.put(config, "project", project_config)
  end

  defp put_project_value(config, key, value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: Map.delete(config, key), else: Map.put(config, key, value)
  end

  defp put_project_value(config, key, nil), do: Map.delete(config, key)
  defp put_project_value(config, key, value), do: Map.put(config, key, value)

  defp put_in_path(config, path, value), do: put_in_path(config, path, value, [nil])

  defp put_in_path(config, path, value, delete_values) do
    case value in delete_values or (is_binary(value) and String.trim(value) == "") do
      true -> delete_in_path(config, path)
      false -> put_in(config, Enum.map(path, &Access.key(&1, %{})), value)
    end
  end

  defp delete_in_path(config, [key]), do: Map.delete(config, key)

  defp delete_in_path(config, [key | rest]) do
    case Map.get(config, key) do
      nested when is_map(nested) -> Map.put(config, key, delete_in_path(nested, rest))
      _ -> config
    end
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
end

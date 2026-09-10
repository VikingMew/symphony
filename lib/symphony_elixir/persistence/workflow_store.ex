defmodule SymphonyElixir.Persistence.WorkflowStore do
  @moduledoc """
  Project and current-workflow persistence plus runtime project overlays.
  """

  import Ecto.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Persistence.{Project, WorkflowRecord}
  alias SymphonyElixir.{Repo, Text, Workflow}

  @default_project_slug "default"

  @spec default_project() ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :not_found | :repo_unavailable}
  def default_project do
    query(:default_project, &default_project!/0)
  end

  defp default_project! do
    if repo_available?() do
      Repo.transaction(fn ->
        SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [1_928_374_651])
        create_default_project_if_empty!()
      end)
    else
      {:error, :repo_unavailable}
    end
  end

  defp create_default_project_if_empty! do
    case Repo.aggregate(Project, :count) do
      0 -> create_default_project!()
      _project_count -> Repo.rollback(:not_found)
    end
  end

  defp create_default_project! do
    case create_project(%{
           name: "Default",
           slug: @default_project_slug,
           default_branch: "main",
           enabled: false
         }) do
      {:ok, project} -> project
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec list_projects() :: [Project.t()]
  def list_projects do
    query(:list_projects, fn ->
      if repo_available?(), do: Repo.all(from(p in Project, order_by: [asc: p.name])), else: []
    end)
  end

  @spec create_project(map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :repo_unavailable}
  def create_project(attrs) do
    if repo_available?(),
      do: %Project{} |> Project.changeset(attrs) |> Repo.insert(),
      else: {:error, :repo_unavailable}
  end

  @spec update_project(Project.t() | String.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :not_found | :repo_unavailable}
  def update_project(%Project{} = project, attrs) do
    if repo_available?(),
      do: project |> Project.changeset(attrs) |> Repo.update(),
      else: {:error, :repo_unavailable}
  end

  def update_project(id, attrs) when is_binary(id) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         %Project{} = project <- Repo.get(Project, id) || {:error, :not_found} do
      update_project(project, attrs)
    end
  end

  @spec import_workflow(Project.t(), String.t(), String.t()) ::
          {:ok, WorkflowRecord.t()} | {:error, term()}
  def import_workflow(%Project{} = project, raw_workflow_md, source \\ "import")
      when is_binary(raw_workflow_md) do
    with {:ok, loaded} <- Workflow.parse_content(raw_workflow_md),
         {:ok, _settings} <- Schema.parse(loaded.config) do
      canonical_raw = Workflow.to_markdown(loaded.config, loaded.prompt)

      upsert_workflow(project, %{
        raw_workflow_md: canonical_raw,
        yaml_config: loaded.config,
        prompt_body: loaded.prompt,
        source: source
      })
    end
  end

  @spec current_workflow() :: WorkflowRecord.t() | nil
  def current_workflow, do: current_workflow(nil)

  @spec current_workflow(Project.t() | nil) :: WorkflowRecord.t() | nil
  def current_workflow(nil) do
    query(:current_workflow, fn ->
      if repo_available?() do
        current_workflow_candidate_projects!()
        |> Enum.find_value(&current_workflow/1)
      end
    end)
  end

  def current_workflow(%Project{id: project_id}) do
    query(:current_workflow, fn ->
      if repo_available?() do
        Repo.one(
          from(w in WorkflowRecord,
            where: w.project_id == ^project_id,
            where: ^test_workflow_source_allowed?() or w.source != "test"
          )
        )
      end
    end)
  end

  @spec workflow_to_loaded(WorkflowRecord.t()) :: Workflow.loaded_workflow()
  def workflow_to_loaded(%WorkflowRecord{} = workflow) do
    config =
      workflow.yaml_config
      |> Kernel.||(%{})
      |> apply_project_runtime_settings(workflow.project_id)

    %{
      config: config,
      prompt: workflow.prompt_body || "",
      prompt_template: workflow.prompt_body || "",
      project_id: workflow.project_id
    }
  end

  @spec export_workflow(WorkflowRecord.t()) :: String.t()
  def export_workflow(%WorkflowRecord{} = workflow),
    do: Workflow.to_markdown(workflow.yaml_config || %{}, workflow.prompt_body || "")

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
    query(:project_for_runtime, fn ->
      if repo_available?(), do: Repo.get(Project, project_id), else: nil
    end)
  end

  defp project_for_runtime(_project_id) do
    query(:project_for_runtime, fn ->
      if repo_available?() do
        current_workflow_candidate_projects!()
        |> List.first()
      end
    end)
  end

  defp current_workflow_candidate_projects! do
    projects = Repo.all(from(p in Project, order_by: [asc: p.name]))

    case Enum.find(projects, &configured_default_project?/1) do
      %Project{} = default_project ->
        [default_project | Enum.reject(projects, &(&1.id == default_project.id))]
        |> Enum.filter(&runtime_project?/1)

      nil ->
        Enum.filter(projects, &runtime_project?/1)
    end
  end

  defp configured_default_project?(%Project{slug: @default_project_slug} = project),
    do: runtime_project?(project)

  defp configured_default_project?(_project), do: false

  defp runtime_project?(%Project{} = project) do
    project.enabled == true and bootstrap_default_placeholder?(project) == false
  end

  defp bootstrap_default_placeholder?(%Project{} = project) do
    project.slug == @default_project_slug and Text.blank?(project.repository_url)
  end

  defp repo_available?, do: Process.whereis(Repo) != nil

  defp query(operation, fun) do
    fun.()
  rescue
    error ->
      log_query_failure(operation, :error, error)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      log_query_failure(operation, kind, reason)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp log_query_failure(operation, kind, reason) do
    Logger.error("Workflow persistence query failed operation=#{operation} outcome=failed kind=#{kind} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
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

    config
    |> Map.put("project", project_config)
    |> apply_project_hooks(project)
  end

  # Per-project hook overlay: workflow-level hooks are the default; a project
  # hook field, when set, overrides the corresponding workflow hook for that
  # project. Unset project hook fields leave the workflow hook in place.
  defp apply_project_hooks(config, %Project{} = project) do
    [
      {"after_create", project.after_create_hook},
      {"before_run", project.before_run_hook},
      {"after_run", project.after_run_hook},
      {"before_remove", project.before_remove_hook}
    ]
    |> Enum.reduce(config, fn {key, value}, acc ->
      if is_binary(value) and String.trim(value) != "" do
        hooks = Map.get(acc, "hooks", %{})
        Map.put(acc, "hooks", Map.put(hooks, key, value))
      else
        acc
      end
    end)
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

  defp upsert_workflow(%Project{} = project, attrs) do
    Repo.transaction(fn ->
      Repo.one!(from(p in Project, where: p.id == ^project.id, lock: "FOR UPDATE"))

      existing = Repo.get_by(WorkflowRecord, project_id: project.id)

      if existing && !workflow_changed?(existing, attrs) do
        existing
      else
        workflow =
          (existing || %WorkflowRecord{})
          |> WorkflowRecord.changeset(Map.put(attrs, :project_id, project.id))
          |> Repo.insert_or_update!()

        workflow
      end
    end)
  end

  defp workflow_changed?(existing, attrs) do
    Enum.any?(
      [:raw_workflow_md, :yaml_config, :prompt_body, :source],
      &(Map.get(existing, &1) != Map.get(attrs, &1))
    )
  end

  defp test_workflow_source_allowed? do
    Application.get_env(:symphony_elixir, :allow_test_workflow_source, false) == true
  end
end

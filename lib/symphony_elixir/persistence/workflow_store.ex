defmodule SymphonyElixir.Persistence.WorkflowStore do
  @moduledoc """
  Project and current-workflow persistence plus runtime project overlays.
  """

  import Ecto.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Config.{LegacyWorkflowConvergence, ProjectIdentity, Schema, WorkflowScopes}
  alias SymphonyElixir.Persistence.{AppSetting, Project, WorkflowRecord}
  alias SymphonyElixir.{Repo, Text, Workflow}

  @default_project_slug "default"
  @instance_workflow_key "instance_workflow"
  @legacy_candidates_key "legacy_instance_workflow_candidates"
  @project_hook_fields [
    {:after_create_hook, "after_create_hook"},
    {:before_run_hook, "before_run_hook"},
    {:after_run_hook, "after_run_hook"},
    {:before_remove_hook, "before_remove_hook"}
  ]
  @project_instance_fields WorkflowScopes.instance_sections() ++ ["prompt_body", "workflow"]
  @type current_workflow_error :: :missing_project_context
  @type legacy_reconciliation_result ::
          {:converged, WorkflowScopes.instance_workflow()}
          | {:already_converged, WorkflowScopes.instance_workflow()}
  @type legacy_reconciliation_error ::
          :repo_unavailable | :zero | {:invalid_selection, String.t()} | {:transaction_failed, term()}
  @type project_identity_status :: %{
          mismatch_count: non_neg_integer(),
          workflows: [%{workflow_id: String.t(), project_id: String.t(), project_slug: String.t()}]
        }

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
    with :ok <- reject_project_hook_fields(attrs) do
      if repo_available?(),
        do: %Project{} |> Project.changeset(attrs) |> Repo.insert(),
        else: {:error, :repo_unavailable}
    end
  end

  @spec update_project(Project.t() | String.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :not_found | :repo_unavailable}
  def update_project(%Project{} = project, attrs) do
    with :ok <- reject_project_hook_fields(attrs) do
      if repo_available?(),
        do: project |> Project.changeset(attrs) |> Repo.update(),
        else: {:error, :repo_unavailable}
    end
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
         {:ok, project_config} <- WorkflowScopes.project_from_loaded(loaded),
         {:ok, _settings} <- Schema.parse(project_config) do
      canonical_raw = Workflow.to_markdown(project_config, "")

      upsert_workflow(project, %{
        raw_workflow_md: canonical_raw,
        yaml_config: project_config,
        prompt_body: "",
        source: source
      })
    end
  end

  @spec import_package(Project.t(), String.t(), String.t()) ::
          {:ok, %{instance_workflow: WorkflowScopes.instance_workflow(), project_workflow: WorkflowRecord.t()}}
          | {:error, term()}
  def import_package(%Project{} = project, raw_workflow_md, source \\ "import")
      when is_binary(raw_workflow_md) do
    with {:ok, loaded} <- Workflow.parse_content(raw_workflow_md),
         {:ok, instance, project_config} <- WorkflowScopes.split_package(loaded.config, loaded.prompt) do
      Repo.transaction(fn ->
        instance = upsert_instance_workflow!(instance)
        project_workflow = upsert_project_workflow!(project, ProjectIdentity.put(project_config, project), source)
        %{instance_workflow: instance, project_workflow: project_workflow}
      end)
    end
  end

  @spec project_identity_status() :: {:ok, project_identity_status()} | {:error, :repo_unavailable}
  def project_identity_status do
    query(:project_identity_status, fn ->
      if repo_available?(), do: {:ok, identity_status(identity_rows())}, else: {:error, :repo_unavailable}
    end)
  end

  @spec reconcile_project_identities() ::
          {:ok, %{updated: non_neg_integer(), status: project_identity_status()}}
          | {:error, :repo_unavailable}
  def reconcile_project_identities do
    if repo_available?() do
      Repo.transaction(&reconcile_project_identities!/0)
    else
      {:error, :repo_unavailable}
    end
  end

  defp reconcile_project_identities! do
    mismatches = identity_rows(lock: true) |> identity_mismatches()

    Enum.each(mismatches, fn {workflow, project} ->
      workflow
      |> WorkflowRecord.changeset(ProjectIdentity.workflow_attrs(workflow, project))
      |> Repo.update!()
    end)

    %{updated: length(mismatches), status: identity_status(identity_rows())}
  end

  @spec put_instance_workflow(map(), String.t()) ::
          {:ok, WorkflowScopes.instance_workflow()} | {:error, term()}
  def put_instance_workflow(config, prompt_body) when is_map(config) and is_binary(prompt_body) do
    with {:ok, instance} <- WorkflowScopes.new_instance(config, prompt_body) do
      Repo.transaction(fn -> upsert_instance_workflow!(instance) end)
    end
  end

  @spec instance_workflow() :: WorkflowScopes.instance_workflow() | nil | {:error, :repo_unavailable}
  def instance_workflow do
    query(:instance_workflow, fn ->
      if repo_available?(), do: load_instance_setting(), else: {:error, :repo_unavailable}
    end)
  end

  @spec legacy_instance_workflow_status() ::
          {:ok, LegacyWorkflowConvergence.status()} | {:error, :repo_unavailable | term()}
  def legacy_instance_workflow_status do
    query(:legacy_instance_workflow_status, fn ->
      if repo_available?() do
        LegacyWorkflowConvergence.status(
          setting_value(@instance_workflow_key),
          setting_value(@legacy_candidates_key)
        )
      else
        {:error, :repo_unavailable}
      end
    end)
  end

  @spec reconcile_legacy_instance_workflow(String.t()) ::
          {:ok, legacy_reconciliation_result()} | {:error, legacy_reconciliation_error()}
  def reconcile_legacy_instance_workflow(project_slug) when is_binary(project_slug) do
    if repo_available?() do
      Repo.transaction(fn -> reconcile_legacy_instance_workflow!(project_slug) end)
    else
      {:error, :repo_unavailable}
    end
  end

  defp load_instance_setting do
    case Repo.get(AppSetting, @instance_workflow_key) do
      nil -> nil
      %AppSetting{value: value} -> load_instance_workflow!(value)
    end
  end

  defp setting_value(key) do
    case Repo.get(AppSetting, key) do
      nil -> nil
      %AppSetting{value: value} -> value
    end
  end

  defp reconcile_legacy_instance_workflow!(project_slug) do
    conflict =
      Repo.one(
        from(setting in AppSetting,
          where: setting.key == ^@legacy_candidates_key,
          lock: "FOR UPDATE"
        )
      )

    case conflict do
      nil -> already_converged_or_zero!()
      %AppSetting{} = setting -> select_and_converge!(setting, project_slug)
    end
  end

  defp already_converged_or_zero! do
    case setting_value(@instance_workflow_key) do
      nil -> Repo.rollback(:zero)
      value -> {:already_converged, load_instance_workflow!(value)}
    end
  end

  defp select_and_converge!(setting, project_slug) do
    case LegacyWorkflowConvergence.select_candidate(setting.value, project_slug) do
      {:ok, instance} ->
        with {:ok, _stored} <- insert_instance_setting(instance),
             {:ok, _deleted} <- Repo.delete(setting) do
          {:converged, instance}
        else
          {:error, reason} -> Repo.rollback({:transaction_failed, reason})
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp insert_instance_setting(instance) do
    %AppSetting{}
    |> AppSetting.changeset(%{
      key: @instance_workflow_key,
      value: WorkflowScopes.dump_instance(instance)
    })
    |> Repo.insert()
  end

  @spec current_workflow() :: WorkflowRecord.t() | nil | {:error, current_workflow_error()}
  def current_workflow, do: current_workflow(nil)

  @spec current_workflow(Project.t() | nil) :: WorkflowRecord.t() | nil | {:error, current_workflow_error()}
  def current_workflow(nil) do
    query(:current_workflow, fn ->
      if repo_available?() do
        current_workflow_candidate_projects!()
        |> current_project_workflows!()
        |> select_current_workflow()
      end
    end)
  end

  def current_workflow(%Project{id: project_id}) do
    query(:current_workflow, fn ->
      if repo_available?() do
        current_workflow_for_project_id!(project_id)
      end
    end)
  end

  defp current_project_workflows!(projects) do
    projects
    |> Enum.flat_map(fn project ->
      case current_workflow_for_project_id!(project.id) do
        nil -> []
        workflow -> [{project, workflow}]
      end
    end)
  end

  defp current_workflow_for_project_id!(project_id) do
    Repo.one(
      from(w in WorkflowRecord,
        where: w.project_id == ^project_id,
        where: ^test_workflow_source_allowed?() or w.source != "test"
      )
    )
  end

  defp select_current_workflow(project_workflows) do
    case Enum.find(project_workflows, fn {project, _workflow} -> configured_default_project?(project) end) do
      {_project, workflow} ->
        workflow

      nil ->
        case project_workflows do
          [] -> nil
          [{_project, workflow}] -> workflow
          _multiple -> {:error, :missing_project_context}
        end
    end
  end

  @spec workflow_to_loaded(WorkflowScopes.instance_workflow(), WorkflowRecord.t()) ::
          {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def workflow_to_loaded(instance, %WorkflowRecord{} = workflow) do
    project_config = apply_project_runtime_settings(workflow.yaml_config || %{}, workflow.project_id)
    WorkflowScopes.compose(instance, project_config, workflow.project_id)
  end

  @spec export_workflow(WorkflowRecord.t()) :: {:ok, String.t()} | {:error, term()}
  def export_workflow(%WorkflowRecord{} = workflow) do
    loaded = %{config: workflow.yaml_config || %{}, prompt: workflow.prompt_body || ""}

    with {:ok, project_config} <- WorkflowScopes.project_from_loaded(loaded) do
      {:ok, Workflow.to_markdown(project_config, "")}
    end
  end

  @spec export_package(WorkflowScopes.instance_workflow(), WorkflowRecord.t()) ::
          {:ok, String.t()} | {:error, term()}
  def export_package(instance, %WorkflowRecord{} = workflow) do
    project_config = apply_project_runtime_settings(workflow.yaml_config || %{}, workflow.project_id)

    with {:ok, loaded} <- WorkflowScopes.combined(instance, project_config) do
      {:ok, Workflow.to_markdown(loaded.config, loaded.prompt)}
    end
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
    query(:project_for_runtime, fn ->
      if repo_available?(), do: Repo.get(Project, project_id), else: nil
    end)
  end

  defp project_for_runtime(_project_id), do: nil

  defp current_workflow_candidate_projects! do
    Project
    |> order_by([p], asc: p.name)
    |> Repo.all()
    |> Enum.filter(&runtime_project?/1)
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

  defp upsert_project_workflow!(project, project_config, source) do
    raw = Workflow.to_markdown(project_config, "")

    case upsert_workflow(project, %{
           raw_workflow_md: raw,
           yaml_config: project_config,
           prompt_body: "",
           source: source
         }) do
      {:ok, workflow} -> workflow
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp upsert_instance_workflow!(instance) do
    value = WorkflowScopes.dump_instance(instance)

    (Repo.get(AppSetting, @instance_workflow_key) || %AppSetting{})
    |> AppSetting.changeset(%{key: @instance_workflow_key, value: value})
    |> Repo.insert_or_update!()

    instance
  end

  defp load_instance_workflow!(value) do
    case WorkflowScopes.load_instance(value) do
      {:ok, instance} -> instance
      {:error, reason} -> raise ArgumentError, "invalid instance workflow: #{inspect(reason)}"
    end
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

  defp identity_rows(lock: true) do
    Repo.all(
      from(w in WorkflowRecord,
        join: p in Project,
        on: p.id == w.project_id,
        order_by: [asc: w.id],
        lock: "FOR UPDATE OF w, p",
        select: {w, p}
      )
    )
  end

  defp identity_rows do
    Repo.all(
      from(w in WorkflowRecord,
        join: p in Project,
        on: p.id == w.project_id,
        order_by: [asc: w.id],
        select: {w, p}
      )
    )
  end

  defp identity_status(rows) do
    workflows =
      rows
      |> identity_mismatches()
      |> Enum.map(fn {workflow, project} ->
        %{workflow_id: workflow.id, project_id: project.id, project_slug: project.slug}
      end)

    %{mismatch_count: length(workflows), workflows: workflows}
  end

  defp identity_mismatches(rows) do
    Enum.reject(rows, fn {workflow, project} -> ProjectIdentity.workflow_matches?(workflow, project) end)
  end

  defp reject_project_hook_fields(attrs) do
    instance_fields =
      attrs
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in @project_instance_fields))

    hook_fields =
      @project_hook_fields
      |> Enum.filter(fn {atom_field, string_field} ->
        Enum.any?([Map.get(attrs, atom_field), Map.get(attrs, string_field)], fn value ->
          is_binary(value) and String.trim(value) != ""
        end)
      end)
      |> Enum.map(&elem(&1, 1))

    invalid = Enum.sort(Enum.uniq(instance_fields ++ hook_fields))

    if invalid == [], do: :ok, else: {:error, {:out_of_scope_project_fields, invalid}}
  end
end

defmodule SymphonyElixir.RepositoryWorkflow do
  @moduledoc """
  Loads and synchronizes the checked-in workflow package into PostgreSQL.

  The repository package is the editable source. PostgreSQL remains the runtime
  snapshot consumed by the orchestrator.
  """

  alias SymphonyElixir.{Persistence, Workflow, WorkflowValidator}

  @source "repository_workflow_package"
  @package_path Path.join(["docs", "examples"])

  @type deps :: %{
          list_projects: (-> [term()]),
          current_workflow: (term() -> term() | nil),
          import_workflow: (term(), String.t(), String.t() -> {:ok, term()} | {:error, term()}),
          read_file: (String.t() -> {:ok, String.t()} | {:error, term()})
        }

  @spec source() :: String.t()
  def source, do: @source

  @spec package_root() :: Path.t()
  def package_root do
    Application.get_env(:symphony_elixir, :repository_workflow_package_path) ||
      Path.join(File.cwd!(), @package_path)
  end

  @spec load(Path.t(), deps()) :: {:ok, String.t()} | {:error, term()}
  def load(root \\ package_root(), deps \\ default_deps()) do
    with {:ok, workflow_yaml} <- deps.read_file.(Path.join(root, "workflow.yml")),
         {:ok, profiles_yaml} <- deps.read_file.(Path.join(root, "profiles.yml")),
         {:ok, loaded} <- Workflow.parse_split_package(workflow_yaml, profiles_yaml),
         raw = Workflow.to_markdown(loaded.config, loaded.prompt),
         {:ok, _validated} <- WorkflowValidator.validate_raw(raw, runtime?: false) do
      {:ok, raw}
    end
  end

  @spec sync(String.t() | :all, Path.t(), deps()) ::
          {:ok, %{changed: non_neg_integer(), unchanged: non_neg_integer()}} | {:error, term()}
  def sync(target, root \\ package_root(), deps \\ default_deps()) do
    with {:ok, raw} <- load(root, deps),
         {:ok, projects} <- select_projects(deps.list_projects.(), target) do
      Enum.reduce_while(projects, {:ok, %{changed: 0, unchanged: 0}}, &sync_project(&1, &2, raw, deps))
    end
  end

  @spec check(String.t() | :all, Path.t(), deps()) :: :ok | {:error, term()}
  def check(target, root \\ package_root(), deps \\ default_deps()) do
    with {:ok, raw} <- load(root, deps),
         {:ok, projects} <- select_projects(deps.list_projects.(), target) do
      case Enum.reject(projects, &synchronized?(deps.current_workflow.(&1), raw)) do
        [] -> :ok
        projects -> {:error, {:workflow_drift, Enum.map(projects, &project_slug/1)}}
      end
    end
  end

  defp select_projects(projects, :all), do: {:ok, Enum.filter(projects, &enabled?/1)}

  defp select_projects(projects, slug) when is_binary(slug) do
    case Enum.find(projects, &(project_slug(&1) == slug)) do
      nil -> {:error, {:project_not_found, slug}}
      project -> {:ok, [project]}
    end
  end

  defp sync_project(project, {:ok, counts}, raw, deps) do
    if synchronized?(deps.current_workflow.(project), raw) do
      {:cont, {:ok, Map.update!(counts, :unchanged, &(&1 + 1))}}
    else
      import_project(project, counts, raw, deps)
    end
  end

  defp import_project(project, counts, raw, deps) do
    case deps.import_workflow.(project, raw, @source) do
      {:ok, _workflow} -> {:cont, {:ok, Map.update!(counts, :changed, &(&1 + 1))}}
      {:error, reason} -> {:halt, {:error, {:import_failed, project_slug(project), reason}}}
    end
  end

  defp current_raw(nil), do: nil
  defp current_raw(workflow), do: Map.fetch!(workflow, :raw_workflow_md)
  defp synchronized?(workflow, raw), do: current_raw(workflow) == raw and Map.fetch!(workflow, :source) == @source
  defp enabled?(project), do: Map.fetch!(project, :enabled)
  defp project_slug(project), do: Map.fetch!(project, :slug)

  defp default_deps do
    %{
      list_projects: &Persistence.list_projects/0,
      current_workflow: &Persistence.current_workflow/1,
      import_workflow: &Persistence.import_workflow/3,
      read_file: &File.read/1
    }
  end
end

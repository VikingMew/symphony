defmodule SymphonyElixir.FirstRunDefaults do
  @moduledoc """
  Explicit first-run import helper for checked-in workflow/profile YAML defaults.

  It imports the repository package into the database only when the operator
  confirms; runtime readers continue to consume the resulting snapshot.
  """

  require Logger

  alias SymphonyElixir.{Persistence, RepositoryWorkflow, Workflow}

  @source "first_run_default_yaml"

  @type deps :: %{
          current_workflow: (-> term() | nil),
          list_projects: (-> [term()]),
          import_workflow: (term(), String.t(), String.t() -> {:ok, term()} | {:error, term()}),
          package_root: (-> String.t()),
          read_file: (String.t() -> {:ok, String.t()} | {:error, term()}),
          prompt: (String.t() -> String.t() | nil),
          interactive?: (-> boolean()),
          log: (atom(), String.t() -> term())
        }

  @spec maybe_import(keyword(), deps()) :: :ok | {:error, term()}
  def maybe_import(opts \\ [], deps \\ default_deps()) do
    cond do
      disabled?(opts) ->
        deps.log.(:info, "Default YAML first-run prompt is disabled.")
        :ok

      deps.current_workflow.() != nil ->
        :ok

      true ->
        maybe_import_for_projects(opts, deps, enabled_projects(deps.list_projects.()))
    end
  end

  defp maybe_import_for_projects(opts, deps, projects) do
    if projects == [] do
      deps.log.(:info, "No enabled projects are configured; start in setup-required mode and configure a project before importing defaults.")
      :ok
    else
      maybe_offer_import(opts, deps, projects)
    end
  end

  defp maybe_offer_import(opts, deps, projects) do
    root = Keyword.get(opts, :package_root) || deps.package_root.()
    workflow_path = Path.join(root, "workflow.yml")
    profiles_path = Path.join(root, "profiles.yml")

    with {:ok, workflow_yaml} <- deps.read_file.(workflow_path),
         {:ok, profiles_yaml} <- deps.read_file.(profiles_path),
         {:ok, loaded} <- Workflow.parse_split_package(workflow_yaml, profiles_yaml) do
      if deps.interactive?.() do
        prompt_for_import(deps, root, loaded, projects)
      else
        deps.log.(
          :info,
          "Default workflow.yml and profiles.yml are available at #{root}, but Symphony is non-interactive; open Settings / Import or restart without --no-default-yaml-prompt to import them."
        )

        :ok
      end
    else
      {:error, :enoent} ->
        deps.log.(:info, "Default YAML package is incomplete; start in setup-required mode and use Settings / Import when ready.")
        :ok

      {:error, reason} ->
        deps.log.(:warning, "Default YAML package could not be imported: #{inspect(reason)}")
        :ok
    end
  end

  defp prompt_for_import(deps, root, loaded, projects) do
    case select_project(deps, root, projects) do
      nil ->
        deps.log.(:info, "Default YAML first-run import declined; start in setup-required mode.")
        :ok

      project ->
        raw = Workflow.to_markdown(loaded.config, loaded.prompt)

        with {:ok, _workflow} <- deps.import_workflow.(project, raw, @source) do
          deps.log.(:info, "Imported default workflow.yml and profiles.yml into the database.")
          :ok
        end
    end
  end

  defp select_project(deps, root, projects) do
    choices =
      projects
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {project, index} -> "  #{index}) #{project_label(project)}" end)

    answer =
      deps.prompt.("No active Symphony workflow is configured. Select an enabled project to import workflow.yml and profiles.yml from #{root}:\n#{choices}\nProject number (blank to skip): ")

    case Integer.parse(String.trim(to_string(answer || ""))) do
      {index, ""} when index > 0 -> Enum.at(projects, index - 1)
      _invalid -> nil
    end
  end

  defp enabled_projects(projects) when is_list(projects) do
    Enum.filter(projects, &(project_value(&1, :enabled) == true))
  end

  defp project_label(project) do
    name = project_value(project, :name) || "Unnamed project"

    case project_value(project, :slug) do
      slug when is_binary(slug) and slug != "" -> "#{name} (#{slug})"
      _missing -> to_string(name)
    end
  end

  defp project_value(project, key) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end

  defp disabled?(opts) do
    Keyword.get(opts, :no_default_yaml_prompt, false) ||
      Application.get_env(:symphony_elixir, :no_default_yaml_prompt, false) ||
      System.get_env("SYMPHONY_NO_DEFAULT_YAML_PROMPT") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp default_deps do
    %{
      current_workflow: &Persistence.current_workflow/0,
      list_projects: &Persistence.list_projects/0,
      import_workflow: &Persistence.WorkflowStore.import_workflow/3,
      package_root: &RepositoryWorkflow.package_root/0,
      read_file: &File.read/1,
      prompt: &IO.gets/1,
      interactive?: &interactive?/0,
      log: fn level, message -> Logger.log(level, message) end
    }
  end

  defp interactive? do
    case Application.get_env(:symphony_elixir, :default_yaml_prompt_interactive) do
      value when is_boolean(value) -> value
      _ -> is_nil(Process.whereis(IEx.Config))
    end
  end
end

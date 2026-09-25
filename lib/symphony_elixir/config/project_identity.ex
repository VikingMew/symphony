defmodule SymphonyElixir.Config.ProjectIdentity do
  @moduledoc """
  Applies the project record's authoritative identity to a workflow slice.
  """

  alias SymphonyElixir.Workflow

  @spec put(map(), map()) :: map()
  def put(config, project) when is_map(config) and is_map(project) do
    config
    |> put_in([Access.key("tracker", %{}), "project_slug"], Map.fetch!(project, :linear_project_slug))
    |> put_in([Access.key("project", %{}), "repository_url"], Map.fetch!(project, :repository_url))
  end

  @spec matches?(map(), map()) :: boolean()
  def matches?(config, project) when is_map(config) and is_map(project) do
    get_in(config, ["tracker", "project_slug"]) == Map.fetch!(project, :linear_project_slug) and
      get_in(config, ["project", "repository_url"]) == Map.fetch!(project, :repository_url)
  end

  @spec workflow_matches?(map(), map()) :: boolean()
  def workflow_matches?(workflow, project) when is_map(workflow) and is_map(project) do
    {:ok, raw} = Workflow.parse_content(Map.fetch!(workflow, :raw_workflow_md))

    matches?(Map.fetch!(workflow, :yaml_config), project) and matches?(raw.config, project)
  end

  @spec workflow_attrs(map(), map()) :: %{yaml_config: map(), raw_workflow_md: String.t()}
  def workflow_attrs(workflow, project) when is_map(workflow) and is_map(project) do
    {:ok, raw} = Workflow.parse_content(Map.fetch!(workflow, :raw_workflow_md))

    %{
      yaml_config: workflow |> Map.fetch!(:yaml_config) |> put(project),
      raw_workflow_md: Workflow.to_markdown(put(raw.config, project), raw.prompt)
    }
  end
end

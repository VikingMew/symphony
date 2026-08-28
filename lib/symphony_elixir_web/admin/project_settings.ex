defmodule SymphonyElixirWeb.Admin.ProjectSettings do
  @moduledoc """
  Pure project settings helpers used by the admin LiveView.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Text

  @compare_fields [
    :name,
    :slug,
    :linear_project_slug,
    :repository_url,
    :default_branch,
    :checkout_depth,
    :source_strategy,
    :worktree_fetch,
    :worktree_cleanup,
    :description,
    :enabled
  ]

  @spec attrs(map()) :: map()
  def attrs(params) do
    %{
      name: Map.get(params, "name", ""),
      slug: Map.get(params, "slug", ""),
      linear_project_slug: blank_as_nil(Map.get(params, "linear_project_slug")),
      repository_url: blank_as_nil(Map.get(params, "repository_url")),
      default_branch: blank_as_nil(Map.get(params, "default_branch")) || "main",
      checkout_depth: parse_checkout_depth(Map.get(params, "checkout_depth")),
      source_strategy: Map.get(params, "source_strategy", "clone"),
      worktree_fetch: truthy_param?(Map.get(params, "worktree_fetch", "true")),
      worktree_cleanup: truthy_param?(Map.get(params, "worktree_cleanup", "true")),
      description: blank_as_nil(Map.get(params, "description")),
      enabled: truthy_param?(Map.get(params, "enabled"))
    }
  end

  @spec changed?(map(), map()) :: boolean()
  def changed?(project, attrs) do
    Enum.any?(@compare_fields, fn field ->
      normalize_value(value(project, field)) != normalize_value(Map.get(attrs, field))
    end)
  end

  @spec repository_preview(map(), [map()]) :: String.t()
  def repository_preview(form, projects) do
    form
    |> repository_base_root()
    |> Path.join(project_cache_name(Enum.find(projects, &value(&1, :enabled)) || List.first(projects)))
  end

  @spec worktree_preview(map()) :: String.t()
  def worktree_preview(form) do
    form
    |> worktree_base_root()
    |> Path.join("CCR-5")
  end

  @spec configuration_missing_items(boolean(), map() | nil) :: [map()]
  def configuration_missing_items(workflow_setup_required, project) do
    []
    |> maybe_add_workflow_item(workflow_setup_required)
    |> maybe_add_project_item(project, :linear_project_slug, "Linear project slug", "Set the Linear project slug on the default project.", "Edit projects")
    |> maybe_add_project_item(project, :repository_url, "Repository URL", "Set the repository URL on the default project so runs can create workspaces.", "Edit projects")
    |> maybe_add_linear_api_token_item()
  end

  @spec scoped_configuration_items([map()], String.t()) :: [map()]
  def scoped_configuration_items(items, scope), do: Enum.filter(items, &(Map.get(&1, :scope) == scope))

  @spec apply_to_workflow_draft(map(), map() | nil) :: map()
  def apply_to_workflow_draft(draft, nil), do: draft

  def apply_to_workflow_draft(draft, project) do
    draft
    |> Map.put("tracker_project_slug", value(project, :linear_project_slug) || "")
    |> Map.put("project_repository_url", value(project, :repository_url) || "")
    |> Map.put("project_default_branch", value(project, :default_branch) || "main")
    |> Map.put("project_checkout_depth", to_string(value(project, :checkout_depth) || 1))
    |> Map.put("project_source_strategy", value(project, :source_strategy) || "clone")
    |> Map.put("project_worktree_fetch", boolean_string(value(project, :worktree_fetch), true))
    |> Map.put("project_worktree_cleanup", boolean_string(value(project, :worktree_cleanup), true))
  end

  @spec value(map() | nil, atom()) :: term()
  def value(nil, _key), do: nil

  def value(project, key) do
    cond do
      Map.has_key?(project, key) -> Map.get(project, key)
      Map.has_key?(project, to_string(key)) -> Map.get(project, to_string(key))
      true -> nil
    end
  end

  @spec team_names(map()) :: String.t()
  def team_names(project) do
    project
    |> Map.get(:teams, [])
    |> Enum.map_join(", ", & &1.name)
  end

  defp maybe_add_workflow_item(items, true) do
    items ++
      [
        %{
          scope: "Workflow",
          title: "Current workflow",
          detail: "Save the draft below to create the project's workflow.",
          href: nil,
          action: nil
        }
      ]
  end

  defp maybe_add_workflow_item(items, _workflow_setup_required), do: items

  defp maybe_add_project_item(items, nil, _key, title, detail, action) do
    items ++ [%{scope: "Project", title: title, detail: detail, href: "/settings/projects", action: action}]
  end

  defp maybe_add_project_item(items, project, key, title, detail, action) do
    if Text.blankish?(value(project, key)) do
      items ++ [%{scope: "Project", title: title, detail: detail, href: "/settings/projects", action: action}]
    else
      items
    end
  end

  defp maybe_add_linear_api_token_item(items) do
    if Text.blankish?(System.get_env("LINEAR_API_KEY")) do
      items ++
        [
          %{
            scope: "Runtime",
            title: "Linear API token",
            detail: "Set LINEAR_API_KEY in the runtime environment before running Linear diagnostics or listening.",
            href: nil,
            action: nil
          }
        ]
    else
      items
    end
  end

  defp repository_base_root(form) do
    case Map.get(form, "workspace_repository_base_root") do
      value when is_binary(value) and value != "" -> value
      _ -> Path.join(workspace_root(form), "repositories")
    end
  end

  defp worktree_base_root(form) do
    case Map.get(form, "workspace_worktree_base_root") do
      value when is_binary(value) and value != "" -> value
      _ -> Path.join(workspace_root(form), "worktrees")
    end
  end

  defp workspace_root(form) do
    case Map.get(form, "workspace_root") do
      value when is_binary(value) and value != "" -> value
      _ -> get_in(Schema.defaults(), ["workspace", "root"])
    end
  end

  defp project_cache_name(nil), do: "project-<hash>"

  defp project_cache_name(project) do
    source = "#{value(project, :repository_url) || "project"}:#{value(project, :default_branch) || "main"}"
    digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    "#{safe_path_segment(Path.basename(value(project, :repository_url) || "project", ".git"))}-#{digest}"
  end

  defp safe_path_segment(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp normalize_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_value(value), do: value

  defp parse_checkout_depth(value) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer > 0 -> integer
      _ -> 1
    end
  end

  defp blank_as_nil(value) do
    value = to_string(value || "") |> String.trim()
    if value == "", do: nil, else: value
  end

  defp truthy_param?(value), do: to_string(value) == "true"

  defp boolean_string(nil, default), do: to_string(default)
  defp boolean_string(value, _default), do: to_string(value)
end

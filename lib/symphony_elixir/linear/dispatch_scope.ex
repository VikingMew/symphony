defmodule SymphonyElixir.Linear.DispatchScope do
  @moduledoc """
  Resolves the installation Linear query scope and the Symphony execution context.
  """

  alias SymphonyElixir.Linear.Issue

  @type dispatch_scope :: %{
          linear_team_key: String.t() | nil,
          linear_project_slug: String.t() | nil,
          fallback_project_slug: String.t() | nil
        }

  @type context_rejection ::
          :linear_project_requires_team
          | {:unknown_linear_team, String.t()}
          | {:unknown_linear_project, String.t()}
          | {:linear_project_team_mismatch, String.t(), String.t()}
          | {:unknown_fallback_project, String.t()}
          | {:disabled_fallback_project, String.t()}
          | :issue_team_out_of_scope
          | :issue_project_out_of_scope
          | :missing_linear_project_context
          | :missing_fallback_project
          | :ambiguous_linear_project_context

  @spec normalize_dispatch_scope(map()) :: dispatch_scope()
  def normalize_dispatch_scope(scope) when is_map(scope) do
    %{
      linear_team_key: optional_value(scope, :linear_team_key),
      linear_project_slug: optional_value(scope, :linear_project_slug),
      fallback_project_slug: optional_value(scope, :fallback_project_slug)
    }
  end

  @spec validate_combination(map()) :: :ok | {:error, :linear_project_requires_team}
  def validate_combination(scope) when is_map(scope) do
    scope = normalize_dispatch_scope(scope)

    if is_nil(scope.linear_team_key) and is_binary(scope.linear_project_slug),
      do: {:error, :linear_project_requires_team},
      else: :ok
  end

  @spec validate_dispatch_settings(map(), map(), [map()]) :: :ok | {:error, context_rejection()}
  def validate_dispatch_settings(scope, discovery, projects)
      when is_map(scope) and is_map(discovery) and is_list(projects) do
    scope = normalize_dispatch_scope(scope)

    with :ok <- validate_combination(scope),
         :ok <- validate_team(scope.linear_team_key, discovery),
         :ok <- validate_linear_project(scope, discovery) do
      validate_fallback(scope.fallback_project_slug, projects)
    end
  end

  @spec active_states([map()]) :: [String.t()]
  def active_states(workflows) when is_list(workflows) do
    workflows
    |> Enum.flat_map(&(get_in(&1, [:config, "tracker", "active_states"]) || []))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec resolve_context(Issue.t(), [map()], map()) ::
          {:ok, map(), Issue.t()} | {:error, context_rejection(), Issue.t()}
  def resolve_context(%Issue{} = issue, workflows, scope) when is_list(workflows) and is_map(scope) do
    scope = normalize_dispatch_scope(scope)

    with :ok <- issue_in_scope(issue, scope),
         {:ok, workflow, source} <- resolve_workflow(issue, workflows, scope) do
      {:ok, workflow, attach_context(issue, workflow, scope, source)}
    else
      {:error, reason} -> {:error, reason, attach_rejection(issue, scope)}
    end
  end

  @spec context_evidence(Issue.t()) :: map()
  def context_evidence(%Issue{} = issue) do
    %{
      "dispatch_scope" => stringify_scope(issue.dispatch_scope),
      "linear_team_key" => issue.team_key,
      "linear_project_slug" => issue.project_slug,
      "symphony_project_id" => issue.symphony_project_id,
      "symphony_project_slug" => issue.symphony_project_slug,
      "context_source" => issue.context_source
    }
  end

  @spec stringify_scope(map() | nil) :: map()
  def stringify_scope(nil), do: stringify_scope(%{})

  def stringify_scope(scope) when is_map(scope) do
    normalized = normalize_dispatch_scope(scope)

    %{
      "linear_team_key" => normalized.linear_team_key,
      "linear_project_slug" => normalized.linear_project_slug,
      "fallback_project_slug" => normalized.fallback_project_slug
    }
  end

  defp validate_team(nil, _discovery), do: :ok

  defp validate_team(team_key, discovery) do
    if Enum.any?(Map.get(discovery, :teams, []), &(scope_project_value(&1, :key) == team_key)),
      do: :ok,
      else: {:error, {:unknown_linear_team, team_key}}
  end

  defp validate_linear_project(%{linear_project_slug: nil}, _discovery), do: :ok

  defp validate_linear_project(scope, discovery) do
    case Enum.find(Map.get(discovery, :projects, []), &(scope_project_value(&1, :slug) == scope.linear_project_slug)) do
      nil ->
        {:error, {:unknown_linear_project, scope.linear_project_slug}}

      project ->
        if Enum.any?(
             scope_project_value(project, :teams) || [],
             &(scope_project_value(&1, :key) == scope.linear_team_key)
           ),
           do: :ok,
           else: {:error, {:linear_project_team_mismatch, scope.linear_team_key, scope.linear_project_slug}}
    end
  end

  defp validate_fallback(nil, _projects), do: :ok

  defp validate_fallback(slug, projects) do
    case Enum.find(projects, &(scope_project_value(&1, :slug) == slug)) do
      nil -> {:error, {:unknown_fallback_project, slug}}
      project -> validate_fallback_enabled(project, slug)
    end
  end

  defp validate_fallback_enabled(project, slug) do
    if scope_project_value(project, :enabled) == true,
      do: :ok,
      else: {:error, {:disabled_fallback_project, slug}}
  end

  defp issue_in_scope(issue, scope) do
    cond do
      is_binary(scope.linear_team_key) and issue.team_key != scope.linear_team_key ->
        {:error, :issue_team_out_of_scope}

      is_binary(scope.linear_project_slug) and issue.project_slug != scope.linear_project_slug ->
        {:error, :issue_project_out_of_scope}

      true ->
        :ok
    end
  end

  defp resolve_workflow(%Issue{project_slug: project_slug}, workflows, _scope)
       when is_binary(project_slug) do
    workflows
    |> Enum.filter(&(get_in(&1, [:config, "tracker", "project_slug"]) == project_slug))
    |> single_workflow("linear_project")
  end

  defp resolve_workflow(%Issue{project_slug: nil}, _workflows, %{fallback_project_slug: nil}),
    do: {:error, :missing_fallback_project}

  defp resolve_workflow(%Issue{project_slug: nil}, workflows, scope) do
    workflows
    |> Enum.filter(&(Map.get(&1, :project_slug) == scope.fallback_project_slug))
    |> single_workflow("fallback")
  end

  defp single_workflow([workflow], source), do: {:ok, workflow, source}
  defp single_workflow([], _source), do: {:error, :missing_linear_project_context}
  defp single_workflow(_workflows, _source), do: {:error, :ambiguous_linear_project_context}

  defp attach_context(issue, workflow, scope, source) do
    %{
      issue
      | dispatch_scope: scope,
        context_source: source,
        symphony_project_id: Map.get(workflow, :project_id),
        symphony_project_slug: Map.get(workflow, :project_slug)
    }
  end

  defp attach_rejection(issue, scope), do: %{issue | dispatch_scope: scope}

  defp optional_value(map, key) do
    value = Map.get(map, key) || Map.get(map, to_string(key))

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp scope_project_value(project, key), do: Map.get(project, key) || Map.get(project, to_string(key))
end

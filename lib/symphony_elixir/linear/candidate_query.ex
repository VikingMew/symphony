defmodule SymphonyElixir.Linear.CandidateQuery do
  @moduledoc """
  Builds the three supported Linear candidate relation-filter shapes.

  The team relation uses `team.key.eq`; its exact external GraphQL shape is
  pinned by offline contract tests because Linear does not publish a complete
  schema example for this combination.
  """

  alias SymphonyElixir.Linear.DispatchScope

  @selection """
  nodes {
    id
    identifier
    title
    description
    priority
    state { name }
    team { key }
    project { slugId }
    branchName
    url
    assignee { id }
    labels { nodes { name } }
    inverseRelations(first: $relationFirst) {
      nodes {
        type
        issue { id identifier state { name } }
      }
    }
    createdAt
    updatedAt
  }
  pageInfo { hasNextPage endCursor }
  """

  @spec build(map(), [String.t()], keyword()) ::
          {String.t(), map(), String.t()} | {:error, :linear_project_requires_team}
  def build(scope, state_names, opts \\ []) when is_map(scope) and is_list(state_names) do
    scope = DispatchScope.normalize_dispatch_scope(scope)

    with :ok <- DispatchScope.validate_combination(scope) do
      first = Keyword.fetch!(opts, :first)
      relation_first = Keyword.fetch!(opts, :relation_first)
      after_cursor = Keyword.get(opts, :after)
      {declarations, filter, scoped_variables, shape} = filter_parts(scope)

      declarations =
        [declarations, "$stateNames: [String!]!", "$first: Int!", "$relationFirst: Int!", "$after: String"]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(", ")

      query = """
      query SymphonyLinearPoll(#{declarations}) {
        issues(filter: {#{filter}state: {name: {in: $stateNames}}}, first: $first, after: $after) {
          #{@selection}
        }
      }
      """

      variables =
        Map.merge(scoped_variables, %{
          stateNames: state_names,
          first: first,
          relationFirst: relation_first,
          after: after_cursor
        })

      {query, variables, shape}
    end
  end

  @spec scope_filter_shape(map()) :: String.t() | {:error, :linear_project_requires_team}
  def scope_filter_shape(scope) when is_map(scope) do
    scope = DispatchScope.normalize_dispatch_scope(scope)

    with :ok <- DispatchScope.validate_combination(scope) do
      {_declarations, _filter, _variables, shape} = filter_parts(scope)
      shape
    end
  end

  defp filter_parts(%{linear_team_key: nil, linear_project_slug: nil}) do
    {"", "", %{}, "state"}
  end

  defp filter_parts(%{linear_team_key: team_key, linear_project_slug: nil}) do
    {"$teamKey: String!", "team: {key: {eq: $teamKey}}, ", %{teamKey: team_key}, "team_state"}
  end

  defp filter_parts(%{linear_team_key: team_key, linear_project_slug: project_slug}) do
    {
      "$teamKey: String!, $projectSlug: String!",
      "team: {key: {eq: $teamKey}}, project: {slugId: {eq: $projectSlug}}, ",
      %{teamKey: team_key, projectSlug: project_slug},
      "team_project_state"
    }
  end
end

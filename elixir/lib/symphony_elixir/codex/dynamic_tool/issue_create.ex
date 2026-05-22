defmodule SymphonyElixir.Codex.DynamicTool.IssueCreate do
  @moduledoc false

  alias SymphonyElixir.{Config, Linear.Client}

  @context_query """
  query SymphonyLinearIssueCreateContext($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        name
        teams(first: 5) {
          nodes {
            id
            name
            states(first: 100) {
              nodes {
                id
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @mutation """
  mutation SymphonyLinearIssueCreate($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        url
        state {
          name
        }
      }
    }
  }
  """

  @allowed_profiles ["nap", "day_dreaming"]
  @payload_keys ["title", "problem", "evidence", "why_it_matters", "suggested_direction", "category", "source_run_id"]
  @required_keys ["title", "problem", "evidence", "why_it_matters", "suggested_direction", "category"]

  @spec execute(map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def execute(arguments, opts) do
    creator = Keyword.get(opts, :issue_creator, fn payload -> default_creator(payload, opts) end)

    with {:ok, profile} <- profile_from_opts(opts),
         :ok <- validate_profile(profile),
         {:ok, payload} <- normalize_arguments(arguments),
         {:ok, result} <- creator.(payload) do
      {:ok, result}
    end
  end

  @spec normalize_arguments(map() | nil) :: {:ok, map()} | {:error, term()}
  def normalize_arguments(arguments) when is_map(arguments) do
    payload =
      arguments
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
      |> Map.take(@payload_keys)

    cond do
      Enum.any?(@required_keys, &blank_string?(Map.get(payload, &1))) ->
        {:error, :invalid_issue_create_payload}

      payload |> Map.values() |> Enum.any?(&(is_binary(&1) and String.length(&1) > 8_000)) ->
        {:error, :issue_create_payload_too_large}

      true ->
        {:ok, payload}
    end
  end

  def normalize_arguments(_arguments), do: {:error, :invalid_issue_create_payload}

  defp validate_profile(profile) when profile in @allowed_profiles, do: :ok
  defp validate_profile(profile), do: {:error, {:issue_create_not_allowed, profile}}

  defp profile_from_opts(opts) do
    case Keyword.get(opts, :profile) do
      profile when is_binary(profile) and profile != "" -> {:ok, profile}
      _ -> {:error, :workflow_profile_unavailable}
    end
  end

  defp default_creator(payload, opts) do
    settings = Config.settings!()
    project_slug = settings.tracker.project_slug
    backlog_state = get_in(settings.workflow, ["backlog_state"]) || "Backlog"

    with project_slug when is_binary(project_slug) and project_slug != "" <- project_slug,
         {:ok, context} <- graphql(opts, @context_query, %{"projectSlug" => project_slug}),
         {:ok, project, team, state} <- context(context, backlog_state),
         input <- input(payload, project, team, state),
         {:ok, response} <- graphql(opts, @mutation, %{"input" => input}) do
      normalize_response(response)
    else
      nil -> {:error, :missing_linear_project_slug}
      "" -> {:error, :missing_linear_project_slug}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :linear_issue_create_context_unavailable}
    end
  end

  defp context(response, backlog_state) do
    with [project | _] <- get_in(response, ["data", "projects", "nodes"]),
         teams when is_list(teams) <- get_in(project, ["teams", "nodes"]),
         {team, state} <- find_team_state(teams, backlog_state) do
      {:ok, project, team, state}
    else
      nil -> {:error, {:linear_state_not_found, backlog_state}}
      [] -> {:error, :linear_project_not_found}
      _ -> {:error, :linear_issue_create_context_unavailable}
    end
  end

  defp find_team_state(teams, backlog_state) do
    Enum.find_value(teams, fn team ->
      state =
        team
        |> get_in(["states", "nodes"])
        |> case do
          states when is_list(states) -> Enum.find(states, &(Map.get(&1, "name") == backlog_state))
          _ -> nil
        end

      if state, do: {team, state}
    end)
  end

  defp input(payload, project, team, state) do
    %{
      "teamId" => Map.fetch!(team, "id"),
      "projectId" => Map.fetch!(project, "id"),
      "stateId" => Map.fetch!(state, "id"),
      "title" => Map.fetch!(payload, "title"),
      "description" => description(payload)
    }
  end

  defp description(payload) do
    [
      {"Problem", Map.get(payload, "problem")},
      {"Evidence", Map.get(payload, "evidence")},
      {"Why it matters", Map.get(payload, "why_it_matters")},
      {"Suggested direction", Map.get(payload, "suggested_direction")},
      {"Category", Map.get(payload, "category")},
      {"Source run", Map.get(payload, "source_run_id")}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) or (is_binary(value) and String.trim(value) == "") end)
    |> Enum.map_join("\n\n", fn {label, value} -> "### #{label}\n#{value}" end)
  end

  defp normalize_response(%{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}) do
    {:ok,
     %{
       "id" => Map.get(issue, "id"),
       "identifier" => Map.get(issue, "identifier"),
       "title" => Map.get(issue, "title"),
       "url" => Map.get(issue, "url"),
       "state" => get_in(issue, ["state", "name"])
     }}
  end

  defp normalize_response(%{"errors" => errors}), do: {:error, {:linear_graphql_errors, errors}}
  defp normalize_response(payload), do: {:error, {:unexpected_issue_create_payload, payload}}

  defp graphql(opts, query, variables) do
    case Keyword.get(opts, :graphql) do
      fun when is_function(fun, 2) -> fun.(query, variables)
      _ -> Client.graphql(query, variables)
    end
  end

  defp blank_string?(value), do: !is_binary(value) or String.trim(value) == ""
end

defmodule SymphonyElixir.Linear.Discovery do
  @moduledoc """
  Fetches read-only Linear metadata useful when configuring Symphony.
  """

  alias SymphonyElixir.Linear.Client

  @linear_endpoint "https://api.linear.app/graphql"

  @viewer_query """
  query SymphonyLinearDiscoveryViewer {
    viewer {
      id
      name
      email
    }
  }
  """

  @teams_query """
  query SymphonyLinearDiscoveryTeams {
    teams(first: 100) {
      nodes {
        id
        key
        name
      }
    }
  }
  """

  @team_states_query """
  query SymphonyLinearDiscoveryTeamStates($teamKey: String!) {
    teams(filter: {key: {eq: $teamKey}}, first: 1) {
      nodes {
        id
        key
        states(first: 100) {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @projects_query """
  query SymphonyLinearDiscoveryProjects {
    projects(first: 100) {
      nodes {
        id
        name
        slugId
        url
        teams {
          nodes {
            id
            key
            name
          }
        }
      }
    }
  }
  """

  @type result :: %{
          fetched_at: DateTime.t(),
          viewer: map(),
          teams: [map()],
          projects: [map()],
          states: [String.t()],
          suggestions: map()
        }

  @spec fetch(keyword()) :: {:ok, result()} | {:error, term()}
  def fetch(opts \\ []) do
    client = Keyword.get(opts, :client_module, client_module())

    with {:ok, tracker} <- discovery_tracker(),
         :ok <- require_token(tracker),
         {:ok, viewer_payload} <- graphql(client, tracker, @viewer_query, "SymphonyLinearDiscoveryViewer"),
         {:ok, teams_payload} <- graphql(client, tracker, @teams_query, "SymphonyLinearDiscoveryTeams"),
         {:ok, projects_payload} <- graphql(client, tracker, @projects_query, "SymphonyLinearDiscoveryProjects"),
         {:ok, team_states_payloads} <- fetch_team_states(client, tracker, teams_payload) do
      normalize_payload(viewer_payload, teams_payload, projects_payload, team_states_payloads)
    end
  end

  defp client_module, do: Application.get_env(:symphony_elixir, :linear_diagnostics_client_module, Client)

  defp discovery_tracker do
    {:ok, %{api_key: System.get_env("LINEAR_API_KEY"), endpoint: @linear_endpoint}}
  end

  defp require_token(%{api_key: token}) when is_binary(token) and token != "", do: :ok
  defp require_token(_tracker), do: {:error, :missing_linear_api_token}

  defp graphql(client, tracker, query, operation_name, variables \\ %{}) do
    opts = [operation_name: operation_name]

    if function_exported?(client, :graphql_with_auth, 5) do
      client.graphql_with_auth(query, variables, tracker.api_key, endpoint(tracker), opts)
    else
      client.graphql(query, variables, opts)
    end
  end

  defp endpoint(%{endpoint: endpoint}) when is_binary(endpoint) and endpoint != "", do: endpoint
  defp endpoint(_tracker), do: @linear_endpoint

  defp fetch_team_states(client, tracker, %{"data" => teams_data}) when is_map(teams_data) do
    teams_data
    |> get_in(["teams", "nodes"])
    |> normalize_team_keys()
    |> Enum.reduce_while({:ok, []}, fn team_key, {:ok, payloads} ->
      case graphql(client, tracker, @team_states_query, "SymphonyLinearDiscoveryTeamStates", %{"teamKey" => team_key}) do
        {:ok, payload} -> {:cont, {:ok, [payload | payloads]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      error -> error
    end
  end

  defp fetch_team_states(_client, _tracker, %{"errors" => errors}), do: {:error, {:linear_graphql_errors, errors}}
  defp fetch_team_states(_client, _tracker, _teams_payload), do: {:ok, []}

  defp normalize_payload(%{"data" => viewer_data}, %{"data" => teams_data}, %{"data" => projects_data}, team_states_payloads)
       when is_map(viewer_data) and is_map(teams_data) and is_map(projects_data) do
    team_states_by_id = normalize_team_states_payloads(team_states_payloads)
    teams = teams_data |> get_in(["teams", "nodes"]) |> normalize_teams(team_states_by_id)
    team_states_by_id = Map.new(teams, &{&1.id, &1.states})
    projects = projects_data |> get_in(["projects", "nodes"]) |> normalize_projects(team_states_by_id)
    states = all_state_names(teams, projects)

    {:ok,
     %{
       fetched_at: DateTime.utc_now(),
       viewer: normalize_viewer(Map.get(viewer_data, "viewer")),
       teams: teams,
       projects: projects,
       states: states,
       suggestions: state_suggestions(states)
     }}
  end

  defp normalize_payload(%{"errors" => errors}, _teams_payload, _projects_payload, _team_states_payloads),
    do: {:error, {:linear_graphql_errors, errors}}

  defp normalize_payload(_viewer_payload, %{"errors" => errors}, _projects_payload, _team_states_payloads),
    do: {:error, {:linear_graphql_errors, errors}}

  defp normalize_payload(_viewer_payload, _teams_payload, %{"errors" => errors}, _team_states_payloads),
    do: {:error, {:linear_graphql_errors, errors}}

  defp normalize_payload(_viewer_payload, _teams_payload, _projects_payload, _team_states_payloads) do
    {:ok,
     %{
       fetched_at: DateTime.utc_now(),
       viewer: %{},
       teams: [],
       projects: [],
       states: [],
       suggestions: state_suggestions([])
     }}
  end

  defp normalize_viewer(viewer) when is_map(viewer) do
    %{
      id: display_value(viewer["id"]),
      name: display_value(viewer["name"]),
      email: display_value(viewer["email"])
    }
  end

  defp normalize_viewer(_viewer), do: %{id: "n/a", name: "n/a", email: "n/a"}

  defp normalize_projects(projects, team_states_by_id) when is_list(projects) do
    projects
    |> Enum.map(&normalize_project(&1, team_states_by_id))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp normalize_projects(_projects, _team_states_by_id), do: []

  defp normalize_project(project, team_states_by_id) when is_map(project) do
    teams = project |> get_in(["teams", "nodes"]) |> normalize_project_teams(team_states_by_id)

    %{
      id: display_value(project["id"]),
      name: display_value(project["name"]),
      slug: display_value(project["slugId"]),
      url: display_value(project["url"]),
      teams: teams,
      states: teams |> Enum.flat_map(& &1.states) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp normalize_project(_project, _team_states_by_id), do: %{id: "n/a", name: "n/a", slug: "n/a", url: "n/a", teams: [], states: []}

  defp normalize_project_teams(teams, team_states_by_id) when is_list(teams) do
    teams
    |> Enum.map(&normalize_project_team(&1, team_states_by_id))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp normalize_project_teams(_teams, _team_states_by_id), do: []

  defp normalize_project_team(team, team_states_by_id) when is_map(team) do
    id = display_value(team["id"])

    %{
      id: id,
      key: display_value(team["key"]),
      name: display_value(team["name"]),
      states: Map.get(team_states_by_id, id, [])
    }
  end

  defp normalize_project_team(_team, _team_states_by_id), do: %{id: "n/a", key: "n/a", name: "n/a", states: []}

  defp normalize_teams(teams, team_states_by_id) when is_list(teams) do
    teams
    |> Enum.map(&normalize_team(&1, team_states_by_id))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp normalize_teams(_teams, _team_states_by_id), do: []

  defp normalize_team(team, team_states_by_id) when is_map(team) do
    id = display_value(team["id"])

    %{
      id: id,
      key: display_value(team["key"]),
      name: display_value(team["name"]),
      states: Map.get(team_states_by_id, id, [])
    }
  end

  defp normalize_team(_team, _team_states_by_id), do: %{id: "n/a", key: "n/a", name: "n/a", states: []}

  defp normalize_team_keys(teams) when is_list(teams) do
    teams
    |> Enum.map(fn
      %{"key" => key} when is_binary(key) -> String.trim(key)
      _team -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_team_keys(_teams), do: []

  defp normalize_team_states_payloads(payloads) when is_list(payloads) do
    payloads
    |> Enum.flat_map(fn
      %{"data" => %{"teams" => %{"nodes" => teams}}} when is_list(teams) -> teams
      _payload -> []
    end)
    |> Map.new(fn team ->
      {display_value(team["id"]), team |> get_in(["states", "nodes"]) |> state_nodes_to_names()}
    end)
  end

  defp normalize_team_states_payloads(_payloads), do: %{}

  defp state_nodes_to_names(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> String.trim(name)
      _node -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp state_nodes_to_names(_nodes), do: []

  defp all_state_names(teams, projects) do
    teams
    |> Enum.flat_map(& &1.states)
    |> Kernel.++(Enum.flat_map(projects, & &1.states))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp state_suggestions(states) do
    %{
      active_states: Enum.filter(states, &active_state?/1),
      terminal_states: Enum.filter(states, &terminal_state?/1),
      review_states: Enum.filter(states, &review_state?/1)
    }
  end

  defp active_state?(state) do
    normalized = normalize_state(state)
    not terminal_state?(state) and normalized not in ["backlog", "todo", "triage"]
  end

  defp terminal_state?(state), do: normalize_state(state) in ["canceled", "cancelled", "closed", "done", "duplicate"]
  defp review_state?(state), do: String.contains?(normalize_state(state), "review")

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp display_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: "n/a", else: trimmed
  end

  defp display_value(_value), do: "n/a"

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end

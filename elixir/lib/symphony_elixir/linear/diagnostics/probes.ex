defmodule SymphonyElixir.Linear.Diagnostics.Probes do
  @moduledoc """
  Read-only Linear diagnostics probe execution and result normalization.
  """

  alias SymphonyElixir.Linear.{Issue, WorkflowStateValidator}

  @viewer_query """
  query SymphonyLinearDiagnosticsViewer {
    viewer {
      id
      name
      email
    }
  }
  """

  @teams_query """
  query SymphonyLinearDiagnosticsTeams {
    teams(first: 100) {
      nodes {
        id
        name
      }
    }
  }
  """

  @project_query """
  query SymphonyLinearDiagnosticsProject($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        name
        slugId
        url
        teams {
          nodes {
            id
            name
            states(first: 100) {
              nodes {
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @type probe_status :: :ok | :warning | :error | :skipped
  @type probe :: %{
          status: probe_status(),
          title: String.t(),
          detail: String.t(),
          data: map()
        }

  @spec run(map(), module()) :: %{probes: map(), issues: [map()]}
  def run(settings, client) do
    tracker = settings.tracker
    api_probe = api_probe(client)
    teams_probe = teams_probe(client)
    project_probe = project_probe(client, tracker.project_slug)
    states_probe = states_probe(project_probe, settings)
    {candidate_probe, issues} = candidate_probe(client)

    %{
      probes: %{
        api: api_probe,
        teams: teams_probe,
        project: project_probe,
        states: states_probe,
        candidates: candidate_probe
      },
      issues: issues
    }
  end

  @spec api_probe(module()) :: probe()
  def api_probe(client) do
    case client.graphql(@viewer_query, %{}, operation_name: "SymphonyLinearDiagnosticsViewer") do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        probe(:ok, "Linear API", "Linear API token authenticated successfully.", %{
          viewer: %{
            id: display_value(viewer["id"]),
            name: display_value(viewer["name"]),
            email: display_value(viewer["email"])
          }
        })

      {:ok, %{"errors" => errors}} ->
        probe(:error, "Linear API", "Linear GraphQL returned errors.", %{errors: sanitize_errors(errors)})

      {:ok, _body} ->
        probe(:error, "Linear API", "Linear API returned an unexpected viewer payload.")

      {:error, reason} ->
        failed_graphql_probe("Linear API", "Linear API probe failed", reason)
    end
  end

  @spec teams_probe(module()) :: probe()
  def teams_probe(client) do
    case client.graphql(@teams_query, %{}, operation_name: "SymphonyLinearDiagnosticsTeams") do
      {:ok, %{"data" => %{"teams" => %{"nodes" => teams}}}} when is_list(teams) ->
        normalized_teams = Enum.map(teams, &normalize_team_summary/1)
        count = length(normalized_teams)

        probe(:ok, "Linear teams", "Fetched #{count} visible Linear team(s).", %{
          teams: normalized_teams,
          team_count: count
        })

      {:ok, %{"errors" => errors}} ->
        probe(:error, "Linear teams", "Linear GraphQL returned errors.", %{errors: sanitize_errors(errors)})

      {:ok, _body} ->
        probe(:error, "Linear teams", "Linear API returned an unexpected teams payload.")

      {:error, reason} ->
        failed_graphql_probe("Linear teams", "Linear teams probe failed", reason)
    end
  end

  @spec project_probe(module(), String.t()) :: probe()
  def project_probe(client, project_slug) do
    variables = %{projectSlug: project_slug}

    case client.graphql(@project_query, variables, operation_name: "SymphonyLinearDiagnosticsProject") do
      {:ok, %{"data" => %{"projects" => %{"nodes" => [project | _]}}}} when is_map(project) ->
        probe(:ok, "Project slug", "Project slug resolved.", %{
          project: normalize_project(project),
          state_names: project_state_names(project)
        })

      {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} ->
        probe(:error, "Project slug", "No Linear project matched slug #{inspect(project_slug)}.")

      {:ok, %{"errors" => errors}} ->
        probe(:error, "Project slug", "Linear GraphQL returned errors.", %{errors: sanitize_errors(errors)})

      {:ok, _body} ->
        probe(:error, "Project slug", "Linear API returned an unexpected project payload.")

      {:error, reason} ->
        failed_graphql_probe("Project slug", "Project slug probe failed", reason, %{
          operation: "SymphonyLinearDiagnosticsProject",
          project_slug: project_slug
        })
    end
  end

  @spec states_probe(probe(), map()) :: probe()
  def states_probe(%{status: :ok, data: %{state_names: state_names}}, settings) do
    validation = WorkflowStateValidator.validate(settings, state_names)
    tracker = settings.tracker
    workflow = settings.workflow

    data =
      validation
      |> Map.merge(%{
        active: tracker.active_states || [],
        terminal: tracker.terminal_states || [],
        human_review_states: Map.get(workflow, "human_review_states", []),
        missing_active: validation.missing.active_states,
        missing_terminal: validation.missing.terminal_states
      })

    if validation.status == :ok do
      probe(:ok, "Workflow states", "All configured workflow states exist in Linear.", data)
    else
      probe(
        :error,
        "Workflow states",
        "Missing Linear states: #{Enum.join(validation.missing_states, ", ")}. Open Settings / Workflow to rename references, or create the missing Linear statuses.",
        data
      )
    end
  end

  def states_probe(_project_probe, _settings) do
    probe(:skipped, "Workflow states", "Skipped because project slug did not resolve.")
  end

  @spec candidate_probe(module()) :: {probe(), [map()]}
  def candidate_probe(client) do
    case client.fetch_candidate_issues() do
      {:ok, issues} ->
        normalized_issues = Enum.map(issues, &normalize_issue/1)
        count = length(normalized_issues)
        {probe(:ok, "Candidate issues", candidate_detail(count), %{issue_count: count}), normalized_issues}

      {:error, reason} ->
        {probe(:error, "Candidate issues", "Candidate issue fetch failed: #{format_reason(reason)}"), []}
    end
  end

  @spec normalize_project(map()) :: map()
  def normalize_project(project) do
    %{
      id: display_value(project["id"]),
      name: display_value(project["name"]),
      slug: display_value(project["slugId"]),
      url: display_value(project["url"]),
      teams: project_teams(project)
    }
  end

  @spec normalize_issue(Issue.t() | map() | term()) :: map()
  def normalize_issue(%Issue{} = issue) do
    %{
      identifier: display_value(issue.identifier),
      title: display_value(issue.title),
      state: display_value(issue.state),
      assignee: if(blank?(issue.assignee_id), do: "unassigned", else: "assigned"),
      labels: issue.labels || [],
      blockers: issue.blocked_by || [],
      updated_at: format_datetime(issue.updated_at),
      url: display_value(issue.url)
    }
  end

  def normalize_issue(issue) when is_map(issue) do
    normalize_issue(struct(Issue, issue))
  end

  def normalize_issue(_issue) do
    %{
      identifier: "n/a",
      title: "n/a",
      state: "n/a",
      assignee: "n/a",
      labels: [],
      blockers: [],
      updated_at: "n/a",
      url: "n/a"
    }
  end

  @spec probe(probe_status(), String.t(), String.t(), map()) :: probe()
  def probe(status, title, detail, data \\ %{}) when status in [:ok, :warning, :error, :skipped] do
    %{status: status, title: title, detail: detail, data: data}
  end

  defp failed_graphql_probe(title, prefix, reason, metadata \\ %{}) do
    case reason do
      {:linear_api_status, status, body} ->
        probe(:error, title, "#{prefix} with HTTP #{status}. See response metadata.", Map.merge(metadata, %{status: status, response: body}))

      {:linear_graphql_errors, errors} ->
        probe(:error, title, "#{prefix}: Linear GraphQL returned errors.", Map.merge(metadata, %{errors: sanitize_errors(errors)}))

      _ ->
        probe(:error, title, "#{prefix}: #{format_reason(reason)}", metadata)
    end
  end

  defp candidate_detail(0) do
    "Fetched 0 candidate issue(s). This means Linear API access worked, but no issues matched the configured project, active states, assignee, and blocker filters."
  end

  defp candidate_detail(count), do: "Fetched #{count} candidate issue(s)."

  defp normalize_team_summary(team) when is_map(team) do
    %{
      id: display_value(team["id"]),
      name: display_value(team["name"])
    }
  end

  defp normalize_team_summary(_team), do: %{id: "n/a", name: "n/a"}

  defp project_state_names(project) do
    project
    |> project_teams()
    |> Enum.flat_map(& &1.states)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp project_teams(%{"teams" => %{"nodes" => teams}}) when is_list(teams) do
    Enum.map(teams, &normalize_team/1)
  end

  defp project_teams(%{"team" => team}) when is_map(team), do: [normalize_team(team)]
  defp project_teams(_project), do: []

  defp normalize_team(team) when is_map(team) do
    %{
      id: display_value(team["id"]),
      name: display_value(team["name"]),
      states: state_nodes_to_names(get_in(team, ["states", "nodes"]))
    }
  end

  defp normalize_team(_team), do: %{id: "n/a", name: "n/a", states: []}

  defp state_nodes_to_names(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      %{"name" => name} -> name
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
  end

  defp state_nodes_to_names(_nodes), do: []

  defp sanitize_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{"message" => message} -> %{"message" => message}
      other -> %{"message" => format_reason(other)}
    end)
  end

  defp sanitize_errors(error), do: [%{"message" => format_reason(error)}]

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: "n/a"

  defp display_value(value) when is_binary(value) do
    if String.trim(value) == "", do: "n/a", else: value
  end

  defp display_value(nil), do: "n/a"
  defp display_value(value), do: to_string(value)

  defp format_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> SymphonyElixir.Redaction.credentials()
  end

  defp blank?(value), do: SymphonyElixir.Text.blank?(value)
end

defmodule SymphonyElixir.Linear.Diagnostics do
  @moduledoc """
  Read-only Linear integration diagnostics for the Web UI.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Linear.Client, Linear.Issue, WorkflowStore}
  require Logger

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
  @type result :: %{
          run_id: String.t(),
          ran_at: DateTime.t(),
          log: [map()],
          config: map(),
          runtime_source: map(),
          probes: map(),
          issues: [map()]
        }

  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    client = Keyword.get(opts, :client_module, client_module())

    workflow_context = workflow_context()
    runtime_source = runtime_source(workflow_context)

    context = run_context(runtime_source)

    result =
      case settings_from_workflow_context(workflow_context) do
        {:ok, settings} ->
          run_with_settings(settings, client, runtime_source)

        {:error, reason} ->
          config_error_result(reason, runtime_source)
      end

    finalize_result(result, context)
  end

  defp workflow_context, do: WorkflowStore.current_with_source()

  defp settings_from_workflow_context({:ok, %{workflow: %{config: config}}}) when is_map(config) do
    Schema.parse(config)
  end

  defp settings_from_workflow_context({:error, reason}), do: {:error, reason}
  defp settings_from_workflow_context(_context), do: {:error, :workflow_config_unavailable}

  defp run_with_settings(settings, client, runtime_source) do
    tracker = settings.tracker
    config = tracker_config(tracker)

    cond do
      tracker.kind != "linear" ->
        skipped_result(config, runtime_source, "Tracker kind is #{inspect(tracker.kind)}; Linear diagnostics are not applicable.")

      blank?(tracker.api_key) ->
        missing_token_result(config, runtime_source)

      blank?(tracker.project_slug) ->
        missing_project_slug_result(config, runtime_source, client)

      true ->
        run_linear_probes(config, tracker, runtime_source, client)
    end
  end

  defp run_linear_probes(config, tracker, runtime_source, client) do
    api_probe = api_probe(client)
    teams_probe = teams_probe(client)
    project_probe = project_probe(client, tracker.project_slug)
    states_probe = states_probe(project_probe, tracker)
    {candidate_probe, issues} = candidate_probe(client)

    %{
      config: config,
      runtime_source: runtime_source,
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

  defp run_context(runtime_source) do
    %{
      run_id: "linear-diagnostics-#{System.unique_integer([:positive, :monotonic])}",
      ran_at: DateTime.utc_now(),
      runtime_source: runtime_source
    }
  end

  defp finalize_result(result, context) do
    log = diagnostics_log(result, context)
    Enum.each(log, &emit_diagnostics_log/1)

    result
    |> Map.put(:run_id, context.run_id)
    |> Map.put(:ran_at, context.ran_at)
    |> Map.put(:log, log)
  end

  defp config_error_result(reason, runtime_source) do
    %{
      config: %{
        tracker_kind: "unavailable",
        endpoint: "n/a",
        project_slug: "n/a",
        assignee: "n/a",
        token_configured: false,
        active_states: [],
        terminal_states: []
      },
      runtime_source: runtime_source,
      probes: %{
        api: probe(:error, "Workflow config", "Cannot load active workflow config: #{format_reason(reason)}"),
        teams: probe(:skipped, "Linear teams", "Skipped because workflow config is unavailable."),
        project: probe(:skipped, "Project slug", "Skipped because workflow config is unavailable."),
        states: probe(:skipped, "Workflow states", "Skipped because workflow config is unavailable."),
        candidates: probe(:skipped, "Candidate issues", "Skipped because workflow config is unavailable.")
      },
      issues: []
    }
  end

  defp skipped_result(config, runtime_source, detail) do
    %{
      config: config,
      runtime_source: runtime_source,
      probes: %{
        api: probe(:skipped, "Linear API", detail),
        teams: probe(:skipped, "Linear teams", detail),
        project: probe(:skipped, "Project slug", detail),
        states: probe(:skipped, "Workflow states", detail),
        candidates: probe(:skipped, "Candidate issues", detail)
      },
      issues: []
    }
  end

  defp missing_token_result(config, runtime_source) do
    %{
      config: config,
      runtime_source: runtime_source,
      probes: %{
        api: probe(:error, "Linear API", "Linear API token is missing."),
        teams: probe(:skipped, "Linear teams", "Skipped because Linear API token is missing."),
        project: probe(:skipped, "Project slug", "Skipped because Linear API token is missing."),
        states: probe(:skipped, "Workflow states", "Skipped because Linear API token is missing."),
        candidates: probe(:skipped, "Candidate issues", "Skipped because Linear API token is missing.")
      },
      issues: []
    }
  end

  defp missing_project_slug_result(config, runtime_source, client) do
    %{
      config: config,
      runtime_source: runtime_source,
      probes: %{
        api: api_probe(client),
        teams: teams_probe(client),
        project: probe(:error, "Project slug", "Linear project slug is missing."),
        states: probe(:skipped, "Workflow states", "Skipped because project slug is missing."),
        candidates: probe(:skipped, "Candidate issues", "Skipped because project slug is missing.")
      },
      issues: []
    }
  end

  defp api_probe(client) do
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

  defp teams_probe(client) do
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

  defp project_probe(client, project_slug) do
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

  defp states_probe(%{status: :ok, data: %{state_names: state_names}}, tracker) do
    active = tracker.active_states || []
    terminal = tracker.terminal_states || []
    available = state_name_set(state_names)
    missing_active = missing_states(active, available)
    missing_terminal = missing_states(terminal, available)

    if missing_active == [] and missing_terminal == [] do
      probe(:ok, "Workflow states", "Configured active and terminal states exist.", %{
        available: state_names,
        active: active,
        terminal: terminal,
        missing_active: [],
        missing_terminal: []
      })
    else
      probe(:error, "Workflow states", "Some configured workflow states were not found in Linear.", %{
        available: state_names,
        active: active,
        terminal: terminal,
        missing_active: missing_active,
        missing_terminal: missing_terminal
      })
    end
  end

  defp states_probe(_project_probe, _tracker) do
    probe(:skipped, "Workflow states", "Skipped because project slug did not resolve.")
  end

  defp candidate_probe(client) do
    case client.fetch_candidate_issues() do
      {:ok, issues} ->
        normalized_issues = Enum.map(issues, &normalize_issue/1)
        count = length(normalized_issues)
        detail = candidate_detail(count)
        {probe(:ok, "Candidate issues", detail, %{issue_count: count}), normalized_issues}

      {:error, reason} ->
        {probe(:error, "Candidate issues", "Candidate issue fetch failed: #{format_reason(reason)}"), []}
    end
  end

  defp tracker_config(tracker) do
    token = token_diagnostics(tracker.api_key)

    %{
      tracker_kind: display_value(tracker.kind),
      endpoint: display_value(tracker.endpoint),
      project_slug: display_value(tracker.project_slug),
      assignee: display_value(tracker.assignee),
      token_configured: token.configured,
      token: token,
      active_states: tracker.active_states || [],
      terminal_states: tracker.terminal_states || []
    }
  end

  defp token_diagnostics(token) do
    metadata = raw_api_key_metadata()

    %{
      configured: !blank?(token),
      source: token_source(metadata),
      raw_setting: metadata.raw_setting,
      env_name: metadata.env_name,
      env_present: metadata.env_present,
      length: token_length(token),
      sha256_prefix: token_fingerprint(token)
    }
  end

  defp raw_api_key_metadata do
    raw_setting =
      case WorkflowStore.current_with_source() do
        {:ok, %{workflow: %{config: %{"tracker" => tracker}}}} when is_map(tracker) ->
          Map.get(tracker, "api_key")

        _ ->
          nil
      end

    env_name = env_reference_name(raw_setting)

    %{
      raw_setting: raw_setting_label(raw_setting),
      env_name: env_name,
      env_present: env_present?(env_name),
      linear_api_key_env_present: !blank?(System.get_env("LINEAR_API_KEY"))
    }
  end

  defp token_source(%{raw_setting: "unset", linear_api_key_env_present: true}), do: "env:LINEAR_API_KEY fallback"
  defp token_source(%{raw_setting: "unset"}), do: "missing"
  defp token_source(%{env_name: env_name, env_present: true}) when is_binary(env_name), do: "env:#{env_name}"

  defp token_source(%{env_name: env_name, env_present: false, linear_api_key_env_present: true}) when is_binary(env_name) do
    "env:#{env_name} missing; using LINEAR_API_KEY fallback"
  end

  defp token_source(%{env_name: env_name}) when is_binary(env_name), do: "env:#{env_name} missing"
  defp token_source(%{raw_setting: "literal"}), do: "workflow literal"
  defp token_source(_metadata), do: "unknown"

  defp raw_setting_label(nil), do: "unset"

  defp raw_setting_label(value) when is_binary(value) do
    case env_reference_name(value) do
      nil -> "literal"
      env_name -> "$#{env_name}"
    end
  end

  defp raw_setting_label(_value), do: "unsupported"

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/), do: env_name
  end

  defp env_reference_name(_value), do: nil

  defp env_present?(env_name) when is_binary(env_name), do: !blank?(System.get_env(env_name))
  defp env_present?(_env_name), do: false

  defp token_length(token) when is_binary(token), do: String.length(token)
  defp token_length(_token), do: 0

  defp token_fingerprint(token) when is_binary(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp token_fingerprint(_token), do: "n/a"

  defp candidate_detail(0) do
    "Fetched 0 candidate issue(s). This means Linear API access worked, but no issues matched the configured project, active states, assignee, and blocker filters."
  end

  defp candidate_detail(count), do: "Fetched #{count} candidate issue(s)."

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

  defp diagnostics_log(result, context) do
    [
      log_entry(:runtime, :ok, "Runtime workflow source resolved.", context.runtime_source),
      config_log_entry(result.config)
      | ordered_probe_log_entries(result.probes)
    ]
  end

  defp config_log_entry(config) do
    metadata =
      Map.take(config, [
        :tracker_kind,
        :endpoint,
        :project_slug,
        :assignee,
        :token_configured,
        :token,
        :active_states,
        :terminal_states
      ])

    log_entry(:config, :ok, "Tracker configuration loaded.", metadata)
  end

  defp ordered_probe_log_entries(probes) do
    [:api, :teams, :project, :states, :candidates]
    |> Enum.flat_map(fn step ->
      case Map.get(probes, step) do
        nil -> []
        probe -> [probe_log_entry(step, probe)]
      end
    end)
  end

  defp probe_log_entry(step, probe) do
    metadata = Map.get(probe, :data, %{})
    log_entry(step, probe.status, probe.detail, metadata)
  end

  defp log_entry(step, status, message, metadata) do
    %{
      step: to_string(step),
      status: status,
      message: message,
      metadata: metadata
    }
  end

  defp emit_diagnostics_log(%{status: status} = entry) when status in [:error, :warning] do
    Logger.warning(fn -> log_line(entry) end)
  end

  defp emit_diagnostics_log(%{step: "runtime"} = entry), do: Logger.info(fn -> log_line(entry) end)
  defp emit_diagnostics_log(_entry), do: :ok

  defp log_line(entry) do
    "linear_diagnostics step=#{entry.step} status=#{entry.status} message=#{entry.message} metadata=#{inspect(entry.metadata, limit: 20, printable_limit: 500)}"
  end

  defp runtime_source(workflow_context) do
    case workflow_context do
      {:ok, %{source: source}} -> format_runtime_source(source)
      {:error, reason} -> %{type: "unavailable", detail: format_reason(reason)}
    end
  end

  defp format_runtime_source(%{type: type} = source) do
    %{
      type: to_string(type),
      detail: runtime_source_detail(source)
    }
  end

  defp format_runtime_source(_source), do: %{type: "unknown", detail: "unknown"}

  defp runtime_source_detail(%{type: :file, path: path}), do: path
  defp runtime_source_detail(%{type: :database, workflow_version_id: id}), do: display_value(id)
  defp runtime_source_detail(%{type: :setup_required}), do: "setup required"
  defp runtime_source_detail(_source), do: "n/a"

  defp normalize_project(project) do
    %{
      id: display_value(project["id"]),
      name: display_value(project["name"]),
      slug: display_value(project["slugId"]),
      url: display_value(project["url"]),
      teams: project_teams(project)
    }
  end

  defp normalize_team_summary(team) when is_map(team) do
    %{
      id: display_value(team["id"]),
      name: display_value(team["name"])
    }
  end

  defp normalize_team_summary(_team), do: %{id: "n/a", name: "n/a"}

  defp normalize_issue(%Issue{} = issue) do
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

  defp normalize_issue(issue) when is_map(issue) do
    normalize_issue(struct(Issue, issue))
  end

  defp normalize_issue(_issue) do
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

  defp state_name_set(names) when is_list(names) do
    names
    |> Enum.map(&normalize_state_name/1)
    |> MapSet.new()
  end

  defp missing_states(configured, available) do
    Enum.reject(configured, fn state -> MapSet.member?(available, normalize_state_name(state)) end)
  end

  defp normalize_state_name(state), do: state |> to_string() |> String.trim() |> String.downcase()

  defp probe(status, title, detail, data \\ %{}) when status in [:ok, :warning, :error, :skipped] do
    %{status: status, title: title, detail: detail, data: data}
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_diagnostics_client_module) ||
      Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

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
    |> String.replace(~r/(Authorization|api[_-]?key|token)(["':=>,\s]+)[^,\]\}\s]+/i, "\\1\\2[REDACTED]")
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end

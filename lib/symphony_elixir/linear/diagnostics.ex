defmodule SymphonyElixir.Linear.Diagnostics do
  @moduledoc """
  Read-only Linear integration diagnostics for the Web UI.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.{Client, Diagnostics.Probes, Health}
  alias SymphonyElixir.{PersistenceProvider, WorkflowStore}
  require Logger

  @linear_tracker_kind "linear"
  @linear_endpoint "https://api.linear.app/graphql"

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

  defp settings_from_workflow_context({:ok, %{workflow: %{setup_required: true}}}), do: {:error, :setup_required}

  defp settings_from_workflow_context({:ok, %{workflow: %{config: config}}}) when is_map(config) do
    with {:ok, settings} <- Schema.parse(config) do
      if settings.tracker.kind == "linear" do
        {:ok, settings}
      else
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}
      end
    end
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
        run_linear_probes(config, settings, runtime_source, client)
    end
  end

  defp run_linear_probes(config, settings, runtime_source, client) do
    %{probes: probes, issues: issues} = Probes.run(settings, client)

    %{
      config: config,
      runtime_source: runtime_source,
      probes: probes,
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
    |> tap(&Health.observe_diagnostics/1)
  end

  defp config_error_result(reason, runtime_source) do
    token = token_diagnostics(System.get_env("LINEAR_API_KEY"))
    detail = config_error_detail(reason)

    %{
      config: %{
        tracker_kind: @linear_tracker_kind,
        endpoint: @linear_endpoint,
        project_slug: "n/a",
        assignee: "n/a",
        token_configured: token.configured,
        token: token,
        active_states: [],
        terminal_states: []
      },
      runtime_source: runtime_source,
      probes: %{
        api: probe(:error, detail.title, detail.message),
        teams: probe(:skipped, "Linear teams", detail.skip_message),
        project: probe(:skipped, "Project slug", detail.skip_message),
        states: probe(:skipped, "Workflow states", detail.skip_message),
        candidates: probe(:skipped, "Candidate issues", detail.skip_message)
      },
      issues: []
    }
  end

  defp config_error_detail(:setup_required) do
    project_items = missing_project_setup_items()

    %{
      title: "Setup required",
      message: setup_required_message(project_items),
      skip_message: setup_required_skip_message(project_items)
    }
  end

  defp config_error_detail(reason) do
    %{
      title: "Runtime configuration",
      message: "Cannot load active runtime configuration: #{format_reason(reason)}",
      skip_message: "Skipped because runtime configuration is unavailable."
    }
  end

  defp setup_required_message([]) do
    "No workflow is configured yet. Open Settings / Workflow to save it, then run Linear diagnostics again."
  end

  defp setup_required_message(project_items) do
    items = Enum.join(project_items, " and ")

    "No workflow is configured yet. Open Settings / Workflow to save it. Open Settings / Projects to set #{items}, then run Linear diagnostics again."
  end

  defp setup_required_skip_message([]), do: "Skipped because no workflow is configured."
  defp setup_required_skip_message(_project_items), do: "Skipped because setup is not complete."

  defp missing_project_setup_items do
    case PersistenceProvider.read(fn -> PersistenceProvider.module().list_projects() end) do
      projects when is_list(projects) ->
        projects
        |> Enum.filter(&(project_value(&1, :enabled) == true))
        |> Enum.map(&project_setup_items/1)
        |> Enum.min_by(&length/1, fn -> all_project_setup_items() end)

      _error ->
        all_project_setup_items()
    end
  rescue
    _exception -> all_project_setup_items()
  catch
    _kind, _reason -> all_project_setup_items()
  end

  defp project_setup_items(project) do
    []
    |> maybe_add_project_setup_item(project, :linear_project_slug, "the Linear project slug")
    |> maybe_add_project_setup_item(project, :repository_url, "the repository URL")
  end

  defp all_project_setup_items, do: ["the Linear project slug", "the repository URL"]

  defp maybe_add_project_setup_item(items, project, key, label) do
    if blank?(project_value(project, key)), do: items ++ [label], else: items
  end

  defp project_value(project, key) do
    Map.get(project, key) || Map.get(project, to_string(key))
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
        api: Probes.api_probe(client),
        teams: Probes.teams_probe(client),
        project: probe(:error, "Project slug", "Linear project slug is missing."),
        states: probe(:skipped, "Workflow states", "Skipped because project slug is missing."),
        candidates: probe(:skipped, "Candidate issues", "Skipped because project slug is missing.")
      },
      issues: []
    }
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
    env_present = !blank?(System.get_env("LINEAR_API_KEY"))

    %{
      configured: !blank?(token),
      source: if(env_present, do: "env:LINEAR_API_KEY", else: "missing env:LINEAR_API_KEY"),
      raw_setting: "env:LINEAR_API_KEY",
      env_name: "LINEAR_API_KEY",
      env_present: env_present,
      length: token_length(token),
      sha256_prefix: token_fingerprint(token)
    }
  end

  defp token_length(token) when is_binary(token), do: String.length(token)
  defp token_length(_token), do: 0

  defp token_fingerprint(token) when is_binary(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp token_fingerprint(_token), do: "n/a"

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

  defp runtime_source({:ok, %{source: source}}), do: format_runtime_source(source)
  defp runtime_source({:error, reason}), do: %{type: "error", detail: format_reason(reason)}

  defp format_runtime_source(%{type: type} = source) do
    %{
      type: to_string(type),
      detail: runtime_source_detail(source)
    }
  end

  defp format_runtime_source(_source), do: %{type: "unknown", detail: "unknown"}

  defp runtime_source_detail(%{type: :database}), do: "current workflow"
  defp runtime_source_detail(%{type: :setup_required}), do: "setup required"
  defp runtime_source_detail(_source), do: "n/a"

  defp probe(status, title, detail, data \\ %{}) when status in [:ok, :warning, :error, :skipped] do
    %{status: status, title: title, detail: detail, data: data}
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_diagnostics_client_module) ||
      Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

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

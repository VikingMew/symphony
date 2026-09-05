defmodule SymphonyElixir.Analytics do
  @moduledoc """
  Database-backed runtime analytics read model.

  This module derives historical metrics from persisted runs, events, projects,
  and agent turns. It deliberately does not read live orchestrator state.
  """

  alias SymphonyElixir.Codex.TokenUsage
  alias SymphonyElixir.{Payload, Persistence, PersistenceProvider}

  @default_limit 2_000
  @range_presets %{
    "24h" => {"Last 24 hours", 24 * 60 * 60},
    "7d" => {"Last 7 days", 7 * 24 * 60 * 60},
    "30d" => {"Last 30 days", 30 * 24 * 60 * 60},
    "all" => {"All time", nil}
  }

  @type summary :: %{
          status: :available,
          range: map(),
          generated_at: DateTime.t(),
          total_runs: non_neg_integer(),
          status_rows: [map()],
          project_rows: [map()],
          issue_rows: [map()],
          execution_mode_rows: [map()],
          failure_rows: [map()],
          event_rows: [map()],
          retry_count: non_neg_integer(),
          blocked_count: non_neg_integer(),
          duration: map(),
          tokens: map(),
          refinement_description: map()
        }

  @type unavailable_summary :: %{
          status: :unavailable,
          range: map(),
          generated_at: DateTime.t(),
          error: PersistenceProvider.read_error()
        }

  @spec summary(keyword()) :: summary() | unavailable_summary()
  def summary(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    persistence = Keyword.get(opts, :persistence, persistence())
    range = range(Keyword.get(opts, :range, "7d"), now)

    with {:ok, runs} <- safe_list_runs(persistence, Keyword.get(opts, :limit, @default_limit)),
         {:ok, events} <- safe_list_events(persistence, Keyword.get(opts, :event_limit, @default_limit)),
         {:ok, projects} <- safe_list_projects(persistence) do
      available_summary(runs, events, projects, range, now)
    else
      {:error, reason} ->
        %{status: :unavailable, range: range, generated_at: now, error: reason}
    end
  end

  defp available_summary(all_runs, all_events, all_projects, range, now) do
    runs = Enum.filter(all_runs, &in_range?(run_time(&1), range))
    events = Enum.filter(all_events, &in_range?(Map.get(&1, :occurred_at), range))
    projects = Map.new(all_projects, &{Map.get(&1, :id), &1})

    %{
      status: :available,
      range: range,
      generated_at: now,
      total_runs: length(runs),
      status_rows: grouped_rows(runs, &run_status/1, "/runs?status="),
      project_rows: project_rows(runs, projects),
      issue_rows: grouped_rows(runs, &issue_identifier/1, "/issues/"),
      execution_mode_rows: grouped_rows(runs, &execution_mode/1, "/runs?execution_mode="),
      failure_rows: failure_rows(runs),
      event_rows: grouped_rows(events, &event_type/1, "/events?event_type="),
      retry_count: count_events(events, "retry"),
      blocked_count: count_events(events, "blocked") + count_status(runs, "blocked"),
      duration: duration_summary(runs),
      tokens: token_summary(events),
      refinement_description: refinement_description_summary(events)
    }
  end

  defp refinement_description_summary(events) do
    samples = Enum.filter(events, &(event_type(&1) == "refinement.description_measurement"))
    chars = samples |> Enum.map(&payload_value(&1, "characters")) |> Enum.sort()
    lines = samples |> Enum.map(&payload_value(&1, "lines")) |> Enum.sort()
    over = Enum.count(samples, &(payload_value(&1, "over_limit") == true))

    %{
      samples: length(samples),
      average_characters: average(chars),
      average_lines: average(lines),
      p95_characters: percentile(chars, 0.95),
      p95_lines: percentile(lines, 0.95),
      over_limit: over,
      over_rate: if(samples == [], do: 0.0, else: over / length(samples))
    }
  end

  defp payload_value(event, key) do
    payload = Map.get(event, :payload, %{})

    atoms = %{
      "characters" => :characters,
      "lines" => :lines,
      "over_limit" => :over_limit
    }

    Payload.get_any(payload, [key, Map.fetch!(atoms, key)])
  end

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  @spec range(String.t() | nil, DateTime.t()) :: map()
  def range(preset, %DateTime{} = now) do
    preset = if Map.has_key?(@range_presets, preset), do: preset, else: "7d"
    {label, seconds} = Map.fetch!(@range_presets, preset)

    %{
      preset: preset,
      label: label,
      from: if(seconds, do: DateTime.add(now, -seconds, :second)),
      to: now
    }
  end

  @spec range_presets() :: [{String.t(), String.t()}]
  def range_presets do
    Enum.map(@range_presets, fn {key, {label, _seconds}} -> {key, label} end)
  end

  defp safe_list_runs(persistence, limit) do
    normalize_list_read(PersistenceProvider.read(fn -> persistence.list_runs(limit: limit) end))
  end

  defp safe_list_events(persistence, limit) do
    normalize_list_read(PersistenceProvider.read(fn -> persistence.list_events(limit: limit) end))
  end

  defp safe_list_projects(persistence) do
    normalize_list_read(PersistenceProvider.read(fn -> persistence.list_projects() end))
  end

  defp normalize_list_read(records) when is_list(records), do: {:ok, records}
  defp normalize_list_read({:error, _reason} = error), do: error
  defp normalize_list_read(other), do: {:error, {:query_failed, {:invalid_read_result, other}}}

  defp grouped_rows(records, key_fun, href_prefix) do
    records
    |> Enum.group_by(key_fun)
    |> Enum.reject(fn {key, _records} -> blank?(key) end)
    |> Enum.map(fn {key, records} ->
      %{
        key: key,
        count: length(records),
        href: href_prefix <> URI.encode(to_string(key)),
        completed: count_status(records, "completed"),
        failed: count_status(records, "failed"),
        blocked: count_status(records, "blocked")
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.key})
  end

  defp project_rows(runs, projects) do
    runs
    |> Enum.group_by(&Map.get(&1, :project_id))
    |> Enum.reject(fn {project_id, _records} -> blank?(project_id) end)
    |> Enum.map(fn {project_id, records} ->
      project = Map.get(projects, project_id, %{})
      name = Map.get(project, :name) || Map.get(project, "name") || project_id
      slug = Map.get(project, :slug) || Map.get(project, "slug") || project_id

      %{
        key: name,
        slug: slug,
        count: length(records),
        href: "/runs?project_id=#{URI.encode(to_string(project_id))}",
        completed: count_status(records, "completed"),
        failed: count_status(records, "failed"),
        blocked: count_status(records, "blocked")
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.key})
  end

  defp failure_rows(runs) do
    runs
    |> Enum.filter(&(run_status(&1) in ["failed", "cancelled", "stopped"]))
    |> grouped_rows(fn run -> Map.get(run, :failure_reason) || "n/a" end, "/runs?failure_reason=")
  end

  defp duration_summary(runs) do
    durations =
      runs
      |> Enum.map(&duration_seconds/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    total = Enum.sum(durations)
    count = length(durations)

    %{
      count: count,
      total_seconds: total,
      average_seconds: if(count == 0, do: 0, else: div(total, count)),
      p50_seconds: percentile(durations, 0.5),
      p95_seconds: percentile(durations, 0.95)
    }
  end

  defp token_summary(events) do
    {run_tokens, standalone_tokens} =
      events
      |> Enum.map(fn event -> {Map.get(event, :run_id), TokenUsage.absolute_usage(Map.get(event, :payload, %{}))} end)
      |> Enum.reject(fn {_run_id, tokens} -> tokens == TokenUsage.zero() end)
      |> Enum.split_with(fn {run_id, _tokens} -> not blank?(run_id) end)

    per_run_tokens =
      run_tokens
      |> Enum.group_by(fn {run_id, _tokens} -> run_id end, fn {_run_id, tokens} -> tokens end)
      |> Map.values()
      |> Enum.map(&max_token_snapshot/1)

    (per_run_tokens ++ Enum.map(standalone_tokens, fn {_run_id, tokens} -> tokens end))
    |> Enum.reduce(TokenUsage.zero(), &sum_tokens/2)
  end

  defp max_token_snapshot(snapshots) do
    Enum.max_by(snapshots, & &1.total_tokens, fn -> TokenUsage.zero() end)
  end

  defp sum_tokens(tokens, acc) do
    %{
      input_tokens: acc.input_tokens + tokens.input_tokens,
      output_tokens: acc.output_tokens + tokens.output_tokens,
      total_tokens: acc.total_tokens + tokens.total_tokens
    }
  end

  defp percentile([], _point), do: 0

  defp percentile(values, point) do
    index =
      values
      |> length()
      |> Kernel.*(point)
      |> Float.ceil()
      |> trunc()
      |> Kernel.-(1)
      |> max(0)

    Enum.at(values, index, 0)
  end

  defp count_events(events, needle) do
    Enum.count(events, fn event ->
      event
      |> event_type()
      |> String.downcase()
      |> String.contains?(needle)
    end)
  end

  defp count_status(records, status) do
    Enum.count(records, &(run_status(&1) == status))
  end

  defp in_range?(_time, %{preset: "all"}), do: true
  defp in_range?(nil, _range), do: false

  defp in_range?(%DateTime{} = time, %{from: from, to: to}) do
    DateTime.compare(time, from) != :lt and DateTime.compare(time, to) != :gt
  end

  defp in_range?(_time, _range), do: false

  defp run_time(run), do: Map.get(run, :finished_at) || Map.get(run, :started_at) || Map.get(run, :inserted_at)

  defp duration_seconds(run) do
    with %DateTime{} = started <- Map.get(run, :started_at),
         %DateTime{} = finished <- Map.get(run, :finished_at) do
      max(DateTime.diff(finished, started, :second), 0)
    else
      _ -> nil
    end
  end

  defp run_status(run), do: normalize_key(Map.get(run, :status))
  defp issue_identifier(run), do: Map.get(run, :issue_identifier) || "n/a"
  defp execution_mode(run), do: Map.get(run, :execution_mode) || "centralized"
  defp event_type(event), do: Map.get(event, :event_type) || "unknown"

  defp normalize_key(value) when is_binary(value), do: value
  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(nil), do: "unknown"
  defp normalize_key(value), do: to_string(value)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp persistence do
    Application.get_env(:symphony_elixir, :persistence_module, Persistence)
  end
end

defmodule SymphonyElixir.Analytics do
  @moduledoc "Database-backed historical and issue-flow analytics read model."
  alias SymphonyElixir.Codex.TokenUsage
  alias SymphonyElixir.{Config, Payload, Persistence, PersistenceProvider}

  @ranges %{"24h" => {"Last 24 hours", 86_400}, "7d" => {"Last 7 days", 604_800}, "30d" => {"Last 30 days", 2_592_000}, "all" => {"All time", nil}}
  @type summary :: map()

  @spec summary(keyword()) :: summary()
  def summary(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    range = range(Keyword.get(opts, :range, "7d"), now)
    store = Keyword.get(opts, :persistence, persistence())

    with {:ok, runs0} <- read(store, :list_analytics_runs),
         {:ok, events0} <- read(store, :list_analytics_events),
         {:ok, issues} <- read(store, :list_analytics_issues),
         {:ok, projects0} <- read(store, :list_projects) do
      runs = Enum.filter(runs0, &inside?(run_time(&1), range))
      events = Enum.filter(events0, &inside?(Map.get(&1, :occurred_at), range))
      projects = Map.new(projects0, &{Map.get(&1, :id), &1})
      thresholds = Keyword.get_lazy(opts, :thresholds, &thresholds/0)

      %{
        status: :available,
        range: range,
        generated_at: now,
        total_runs: length(runs),
        status_rows: rows(runs, &status/1, "/runs?status="),
        project_rows: project_rows(runs, projects),
        issue_rows: rows(runs, &identifier/1, "/issues/"),
        execution_mode_rows: rows(runs, &(Map.get(&1, :execution_mode) || "centralized"), "/runs?execution_mode="),
        failure_rows: rows(Enum.filter(runs, &(status(&1) in ["failed", "cancelled", "stopped"])), &(Map.get(&1, :failure_reason) || "n/a"), "/runs?failure_reason="),
        event_rows: rows(events, &event_type/1, "/events?event_type="),
        retry_count: count_events(events, "retry"),
        blocked_count: count_events(events, "blocked") + Enum.count(runs, &(status(&1) == "blocked")),
        duration: durations(runs),
        tokens: tokens(events),
        refinement_description: refinement_description(events),
        issue_quality: quality(runs, events0, issues, range, now, thresholds),
        coverage: %{complete: true, truncated: false}
      }
    else
      {:error, reason} -> %{status: :unavailable, range: range, generated_at: now, error: reason}
    end
  end

  defp refinement_description(events) do
    samples = Enum.filter(events, &(event_type(&1) == "refinement.description_measurement"))
    characters = samples |> Enum.map(&description_measurement(&1, "characters")) |> Enum.sort()
    lines = samples |> Enum.map(&description_measurement(&1, "lines")) |> Enum.sort()
    over_limit = Enum.count(samples, &(description_measurement(&1, "over_limit") == true))

    %{
      samples: length(samples),
      average_characters: average_or_zero(characters),
      average_lines: average_or_zero(lines),
      p95_characters: percentile(characters, 0.95),
      p95_lines: percentile(lines, 0.95),
      over_limit: over_limit,
      over_rate: if(samples == [], do: 0.0, else: over_limit / length(samples))
    }
  end

  defp description_measurement(event, key) do
    atom_keys = %{"characters" => :characters, "lines" => :lines, "over_limit" => :over_limit}
    Payload.get_any(Map.get(event, :payload, %{}), [key, Map.fetch!(atom_keys, key)])
  end

  @spec range(String.t() | nil, DateTime.t()) :: map()
  def range(key, now) do
    key = if Map.has_key?(@ranges, key), do: key, else: "7d"
    {label, seconds} = Map.fetch!(@ranges, key)
    %{preset: key, label: label, from: if(seconds, do: DateTime.add(now, -seconds)), to: now}
  end

  @spec range_presets() :: [{String.t(), String.t()}]
  def range_presets, do: Enum.map(@ranges, fn {key, {label, _}} -> {key, label} end)

  # Cohort construction is kept together so every metric visibly shares the same boundary rules.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp quality(runs, all_events, issues, range, now, t) do
    ids = runs |> Enum.filter(&(Map.get(&1, :kind, "issue") == "issue")) |> MapSet.new(&identifier/1)
    events = Enum.filter(all_events, &inside?(Map.get(&1, :occurred_at), range))
    issue_map = Map.new(issues, &{Map.get(&1, :identifier), &1})
    den = MapSet.size(ids)
    refinements = Map.new(ids, fn id -> {id, Enum.count(runs, &(identifier(&1) == id and Map.get(&1, :profile) == "refinement"))} end)
    avg = average(Map.values(refinements))
    handoffs = implementation_handoffs(events, runs)
    first = first_by_issue(handoffs)
    returns = transitions(all_events, "Ready to Merge", "In Progress")

    returned =
      Enum.reduce(first, MapSet.new(), fn {id, event}, acc ->
        if Enum.any?(returns, &(identifier(&1) == id and between?(Map.get(&1, :occurred_at), Map.get(event, :occurred_at), now))), do: MapSet.put(acc, id), else: acc
      end)

    hden = map_size(first)
    rr = rate(MapSet.size(returned), hden)

    blocked =
      Enum.count(ids, fn id ->
        Enum.any?(runs, &(identifier(&1) == id and status(&1) == "blocked")) or Enum.any?(events, &(identifier(&1) == id and String.contains?(String.downcase(event_type(&1)), "blocked"))) or
          is_map(Map.get(Map.get(issue_map, id, %{}), :blocking_decision))
      end)

    lengths =
      Enum.map(ids, fn id ->
        case nested(Map.get(Map.get(issue_map, id, %{}), :snapshot, %{}), ["description"]) do
          value when is_binary(value) -> String.length(value)
          _ -> nil
        end
      end)

    present = Enum.reject(lengths, &is_nil/1) |> Enum.sort()
    davg = average(present)
    counts = Enum.frequencies_by(handoffs, &identifier/1)
    rework = Enum.count(Map.keys(first), &(MapSet.member?(returned, &1) or Map.get(counts, &1, 0) > 1))
    created = MapSet.size(MapSet.intersection(ids, created_ids(all_events)))

    %{
      refinement: %{
        denominator: den,
        distribution: %{zero: count(refinements, 0), one: count(refinements, 1), two: count(refinements, 2), three_plus: Enum.count(refinements, fn {_, n} -> n >= 3 end)},
        average: avg,
        warning: above?(avg, t.refinement_rounds_average_max)
      },
      review_return: %{numerator: MapSet.size(returned), denominator: hden, pending_censored: hden - MapSet.size(returned), rate: rr, warning: above?(rr, t.first_handoff_observed_return_rate_max)},
      blocked: rate_metric(blocked, den, t.blocked_rate_max),
      description: %{denominator: length(present), missing: Enum.count(lengths, &is_nil/1), average: davg, p50: percentile_nil(present), warning: below?(davg, t.latest_description_length_min)},
      rework: rate_metric(rework, hden, t.rework_rate_max),
      origin: %{
        status: if(created == 0, do: :insufficient_coverage, else: :available),
        agent_created: created,
        external_unknown: den - created,
        denominator: den,
        agent_rate: rate(created, den),
        unknown_rate: rate(den - created, den)
      },
      token_rows: token_rows(events, runs, t.per_issue_total_tokens_max)
    }
  end

  defp transitions(events, from, to), do: Enum.filter(events, &(event_type(&1) == "linear.state_transition" and (is_nil(from) or payload(&1, "from_state") == from) and payload(&1, "to_state") == to))

  defp implementation_handoffs(events, runs) do
    implementation_run_ids =
      runs
      |> Enum.filter(&(Map.get(&1, :kind, "issue") == "issue" and Map.get(&1, :profile) == "implementation"))
      |> MapSet.new(&Map.get(&1, :id))

    events
    |> transitions(nil, "Ready to Merge")
    |> Enum.filter(&MapSet.member?(implementation_run_ids, Map.get(&1, :run_id)))
  end

  defp first_by_issue(events),
    do:
      events
      |> Enum.filter(&match?(%DateTime{}, Map.get(&1, :occurred_at)))
      |> Enum.group_by(&identifier/1)
      |> Map.new(fn {id, list} -> {id, Enum.min_by(list, &Map.fetch!(&1, :occurred_at), DateTime)} end)

  defp created_ids(events),
    do:
      events
      |> Enum.filter(&(event_type(&1) == "linear.tool_call" and payload(&1, "tool") == "linear_issue_create" and payload(&1, "status") == "success"))
      |> MapSet.new(&nested(Map.get(&1, :payload, %{}), ["result", "identifier"]))

  defp token_rows(events, runs, threshold) do
    by_id =
      runs
      |> Enum.filter(&(Map.get(&1, :kind, "issue") == "issue"))
      |> Map.new(&{Map.get(&1, :id), &1})

    events
    |> Enum.filter(&(event_type(&1) == "codex.update" and Map.has_key?(by_id, Map.get(&1, :run_id))))
    |> Enum.group_by(&Map.get(&1, :run_id))
    |> Enum.map(fn {id, list} ->
      run = Map.fetch!(by_id, id)
      {{Map.get(run, :profile) || "unknown", identifier(run)}, list |> Enum.map(&TokenUsage.absolute_usage(Map.get(&1, :payload, %{}))) |> max_snapshot()}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {{profile, id}, usages} ->
      usage = Enum.reduce(usages, TokenUsage.zero(), &sum/2)
      %{profile: profile, issue_identifier: id, tokens: usage, warning: above?(usage.total_tokens, threshold)}
    end)
    |> Enum.sort_by(&{&1.profile, &1.issue_identifier})
  end

  defp read(store, fun) do
    normalize(PersistenceProvider.read(fn -> analytics_read(store, fun) end))
  end

  defp analytics_read(store, :list_analytics_runs) do
    if function_exported?(store, :list_analytics_runs, 0),
      do: store.list_analytics_runs(),
      else: store.list_runs(limit: 2_000)
  end

  defp analytics_read(store, :list_analytics_events) do
    if function_exported?(store, :list_analytics_events, 0),
      do: store.list_analytics_events(),
      else: store.list_events(limit: 2_000)
  end

  defp analytics_read(store, :list_analytics_issues) do
    if function_exported?(store, :list_analytics_issues, 0), do: store.list_analytics_issues(), else: []
  end

  defp analytics_read(store, fun), do: apply(store, fun, [])
  defp normalize(v) when is_list(v), do: {:ok, v}
  defp normalize({:error, _} = e), do: e
  defp normalize(v), do: {:error, {:query_failed, {:invalid_read_result, v}}}

  defp rows(records, key, prefix),
    do:
      records
      |> Enum.group_by(key)
      |> Enum.map(fn {k, v} ->
        %{
          key: k,
          count: length(v),
          href: prefix <> URI.encode(to_string(k)),
          completed: Enum.count(v, &(status(&1) == "completed")),
          failed: Enum.count(v, &(status(&1) == "failed")),
          blocked: Enum.count(v, &(status(&1) == "blocked"))
        }
      end)
      |> Enum.sort_by(&{-&1.count, &1.key})

  defp project_rows(runs, projects),
    do:
      runs
      |> Enum.group_by(&Map.get(&1, :project_id))
      |> Enum.map(fn {id, list} ->
        p = Map.get(projects, id, %{})

        %{
          key: Map.get(p, :name) || id,
          slug: Map.get(p, :slug) || id,
          count: length(list),
          href: "/runs?project_id=#{id}",
          completed: Enum.count(list, &(status(&1) == "completed")),
          failed: Enum.count(list, &(status(&1) == "failed")),
          blocked: Enum.count(list, &(status(&1) == "blocked"))
        }
      end)

  defp durations(runs) do
    values = runs |> Enum.map(&duration/1) |> Enum.reject(&is_nil/1) |> Enum.sort()

    %{
      count: length(values),
      total_seconds: Enum.sum(values),
      average_seconds: if(values == [], do: 0, else: div(Enum.sum(values), length(values))),
      p50_seconds: percentile(values, 0.5),
      p95_seconds: percentile(values, 0.95)
    }
  end

  defp tokens(events) do
    events
    |> Enum.map(&{Map.get(&1, :run_id), TokenUsage.absolute_usage(Map.get(&1, :payload, %{}))})
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.values()
    |> Enum.map(&max_snapshot/1)
    |> Enum.reduce(TokenUsage.zero(), &sum/2)
  end

  defp max_snapshot(v), do: Enum.max_by(v, & &1.total_tokens, fn -> TokenUsage.zero() end)
  defp sum(v, a), do: %{input_tokens: a.input_tokens + v.input_tokens, output_tokens: a.output_tokens + v.output_tokens, total_tokens: a.total_tokens + v.total_tokens}

  defp duration(r) do
    case {Map.get(r, :started_at), Map.get(r, :finished_at)} do
      {%DateTime{} = a, %DateTime{} = b} -> max(DateTime.diff(b, a), 0)
      _ -> nil
    end
  end

  defp percentile([], _), do: 0
  defp percentile(v, p), do: Enum.at(v, max(ceil(length(v) * p) - 1, 0), 0)
  defp percentile_nil([]), do: nil
  defp percentile_nil(v), do: percentile(v, 0.5)
  defp count_events(e, n), do: Enum.count(e, &String.contains?(String.downcase(event_type(&1)), n))
  defp count(m, n), do: Enum.count(m, fn {_, v} -> v == n end)
  defp rate(_, 0), do: nil
  defp rate(n, d), do: n / d
  defp average([]), do: nil
  defp average(v), do: Enum.sum(v) / length(v)
  defp average_or_zero([]), do: 0.0
  defp average_or_zero(v), do: Enum.sum(v) / length(v)

  defp rate_metric(n, d, t) do
    v = rate(n, d)
    %{numerator: n, denominator: d, rate: v, warning: above?(v, t)}
  end

  defp above?(nil, _), do: false
  defp above?(_, nil), do: false
  defp above?(v, t), do: v > t
  defp below?(nil, _), do: false
  defp below?(_, nil), do: false
  defp below?(v, t), do: v < t
  defp inside?(_, %{preset: "all"}), do: true
  defp inside?(%DateTime{} = v, %{from: f, to: t}), do: between?(v, f, t)
  defp inside?(_, _), do: false
  defp between?(%DateTime{} = v, %DateTime{} = f, %DateTime{} = t), do: DateTime.compare(v, f) != :lt and DateTime.compare(v, t) != :gt
  defp between?(_, _, _), do: false
  defp run_time(r), do: Map.get(r, :finished_at) || Map.get(r, :started_at) || Map.get(r, :inserted_at)
  defp status(r), do: to_string(Map.get(r, :status) || "unknown")
  defp identifier(r), do: Map.get(r, :issue_identifier) || "n/a"
  defp event_type(e), do: Map.get(e, :event_type) || "unknown"
  defp payload(e, k), do: nested(Map.get(e, :payload, %{}), [k])
  defp nested(v, []), do: v
  defp nested(m, [k | r]) when is_map(m), do: nested(Map.get(m, k) || Map.get(m, atom_key(k)), r)
  defp nested(_, _), do: nil
  defp atom_key("description"), do: :description
  defp atom_key("from_state"), do: :from_state
  defp atom_key("identifier"), do: :identifier
  defp atom_key("result"), do: :result
  defp atom_key("status"), do: :status
  defp atom_key("to_state"), do: :to_state
  defp atom_key("tool"), do: :tool

  defp thresholds do
    case Config.settings() do
      {:ok, s} -> s.analytics
      {:error, _} -> struct(SymphonyElixir.Config.Schema.Analytics)
    end
  end

  defp persistence, do: Application.get_env(:symphony_elixir, :persistence_module, Persistence)
end

defmodule SymphonyElixirWeb.DashboardPresenter do
  @moduledoc """
  Pure presentation helpers for the operations dashboard LiveView.
  """

  alias SymphonyElixir.Payload

  @spec total_runtime_seconds(map(), DateTime.t()) :: non_neg_integer()
  def total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(Map.get(payload, :running, []), 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  @spec format_runtime_and_turns(term(), term(), DateTime.t()) :: String.t()
  def format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  def format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  @spec format_runtime_seconds(number()) :: String.t()
  def format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  @spec format_int(term()) :: String.t()
  def format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  def format_int(_value), do: "n/a"

  @spec format_time(term()) :: String.t()
  def format_time(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def format_time(value), do: to_string(value)

  @spec rate_limit_status_label(atom()) :: String.t()
  def rate_limit_status_label(:available), do: "available"
  def rate_limit_status_label(:unrecognized), do: "unrecognized"
  def rate_limit_status_label(_status), do: "not received"

  @spec rate_limit_badge_class(atom()) :: String.t()
  def rate_limit_badge_class(:available), do: "status-badge status-success"
  def rate_limit_badge_class(:unrecognized), do: "status-badge status-warning"
  def rate_limit_badge_class(_status), do: "status-badge status-info"

  @spec rate_limit_plan_context(map() | nil) :: String.t()
  def rate_limit_plan_context(snapshot) when is_map(snapshot) do
    parts =
      []
      |> append_present("Plan", Payload.get_any(snapshot, ["plan_type", :plan_type, "planType", :planType]))
      |> append_present("Limit", Payload.get_any(snapshot, ["limit_id", :limit_id, "limitId", :limitId]))
      |> append_present("Name", Payload.get_any(snapshot, ["limit_name", :limit_name, "limitName", :limitName]))
      |> append_present("Reached", Payload.get_any(snapshot, ["rate_limit_reached_type", :rate_limit_reached_type, "rateLimitReachedType", :rateLimitReachedType]))

    if parts == [], do: "No plan metadata supplied.", else: Enum.join(parts, " · ")
  end

  def rate_limit_plan_context(_snapshot), do: "No plan metadata supplied."

  @spec rate_limit_bucket_summaries(map() | nil) :: [map()]
  def rate_limit_bucket_summaries(snapshot) when is_map(snapshot) do
    [
      bucket_summary("Primary", Payload.get_any(snapshot, ["primary", :primary])),
      bucket_summary("Secondary", Payload.get_any(snapshot, ["secondary", :secondary]))
    ]
    |> Enum.reject(&is_nil/1)
  end

  def rate_limit_bucket_summaries(_snapshot), do: []

  @spec state_badge_class(term()) :: String.t()
  def state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  @spec listening_enabled?(map()) :: boolean()
  def listening_enabled?(payload) do
    listening_mode(payload) != "not_listening"
  end

  @spec listening_mode(map()) :: String.t()
  def listening_mode(payload) do
    polling = Map.get(payload, :polling, %{})

    case Map.get(polling, :listening_mode) || Map.get(polling, "listening_mode") do
      mode when mode in ["listening_all", :listening_all] -> "listening_all"
      mode when mode in ["listening_refine_only", :listening_refine_only] -> "listening_refine_only"
      mode when mode in ["not_listening", :not_listening] -> "not_listening"
      _ -> if Map.get(polling, :listening?, Map.get(polling, "listening?", false)), do: "listening_all", else: "not_listening"
    end
  end

  @spec listening_label(map()) :: String.t()
  def listening_label(payload) do
    case listening_mode(payload) do
      "listening_all" -> "all active work"
      "listening_refine_only" -> "refinement only"
      _ -> "disabled"
    end
  end

  @spec listening_badge_class(map()) :: String.t()
  def listening_badge_class(payload) do
    case listening_mode(payload) do
      "listening_refine_only" -> "status-badge status-warning"
      "listening_all" -> "status-badge status-success"
      _ -> "status-badge status-danger"
    end
  end

  @spec history_badge_class(atom()) :: String.t()
  def history_badge_class(:error), do: "status-badge status-danger"
  def history_badge_class(:warning), do: "status-badge status-warning"
  def history_badge_class(_severity), do: "status-badge status-info"

  @spec history_source_badge_class(term()) :: String.t()
  def history_source_badge_class(:system), do: "status-badge"
  def history_source_badge_class("system"), do: "status-badge"
  def history_source_badge_class(:linear), do: "status-badge status-accent"
  def history_source_badge_class("linear"), do: "status-badge status-accent"
  def history_source_badge_class(_source), do: "status-badge status-info"

  @spec history_source_label(term()) :: String.t()
  def history_source_label(nil), do: "agent"
  def history_source_label(source), do: source |> to_string() |> String.replace("_", " ")

  @spec session_history_key(map()) :: String.t()
  def session_history_key(entry) do
    cond do
      Map.get(entry, :run_id) not in [nil, ""] -> Map.get(entry, :run_id)
      Map.get(entry, :issue_id) not in [nil, ""] -> Map.get(entry, :issue_id)
      Map.get(entry, :issue_identifier) not in [nil, ""] -> Map.get(entry, :issue_identifier)
      true -> Map.get(entry, :session_id) || "unknown"
    end
  end

  @spec session_history_expanded?(MapSet.t(), map()) :: boolean()
  def session_history_expanded?(expanded_session_histories, entry) do
    MapSet.member?(expanded_session_histories, session_history_key(entry))
  end

  @spec session_history_summary(map()) :: String.t()
  def session_history_summary(entry) do
    visible_count = length(Map.get(entry, :session_history, []) || [])
    total_count = Map.get(entry, :session_history_total_count) || visible_count

    if total_count > visible_count do
      "Session history (#{visible_count} rows from #{total_count} events)"
    else
      "Session history (#{visible_count})"
    end
  end

  @spec toggle_session_history_key(MapSet.t(), String.t()) :: MapSet.t()
  def toggle_session_history_key(expanded_session_histories, key) do
    if MapSet.member?(expanded_session_histories, key) do
      MapSet.delete(expanded_session_histories, key)
    else
      MapSet.put(expanded_session_histories, key)
    end
  end

  @spec pretty_value(term()) :: String.t()
  def pretty_value(nil), do: "n/a"
  def pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  @spec rate_limit_debug_source(map()) :: term()
  def rate_limit_debug_source(debug), do: debug_value(debug, :source_path, "n/a")

  @spec rate_limit_debug_method(map()) :: term()
  def rate_limit_debug_method(debug), do: debug_value(debug, :method, "n/a")

  @spec rate_limit_debug_reason(map()) :: term()
  def rate_limit_debug_reason(debug), do: debug_value(debug, :reason, "No parser failure reason recorded.")

  @spec rate_limit_debug_truncated?(map()) :: boolean()
  def rate_limit_debug_truncated?(debug), do: debug_value(debug, :truncated, false) == true

  @spec rate_limit_debug_payload(map()) :: String.t()
  def rate_limit_debug_payload(debug) do
    debug
    |> debug_value(:payload, nil)
    |> pretty_value()
    |> truncate_string(2_000)
  end

  @spec truncate_string(String.t(), pos_integer()) :: String.t()
  def truncate_string(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes,
    do: binary_part(value, 0, max_bytes) <> "... (truncated)"

  def truncate_string(value, _max_bytes), do: value

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp append_present(parts, _label, value) when value in [nil, ""], do: parts
  defp append_present(parts, label, value), do: parts ++ ["#{label} #{value}"]

  defp bucket_summary(_label, bucket) when not is_map(bucket), do: nil

  defp bucket_summary(label, bucket) do
    %{
      label: label,
      used_percent: Payload.get_any(bucket, ["used_percent", :used_percent, "usedPercent", :usedPercent]),
      window_duration: format_window_duration(Payload.get_any(bucket, ["window_duration_mins", :window_duration_mins, "windowDurationMins", :windowDurationMins])),
      resets_at: format_reset_time(Payload.get_any(bucket, ["resets_at", :resets_at, "resetsAt", :resetsAt]))
    }
  end

  defp format_window_duration(minutes) when is_integer(minutes) do
    cond do
      rem(minutes, 10_080) == 0 -> "#{div(minutes, 10_080)}w"
      rem(minutes, 1_440) == 0 -> "#{div(minutes, 1_440)}d"
      rem(minutes, 60) == 0 -> "#{div(minutes, 60)}h"
      true -> "#{minutes}m"
    end
  end

  defp format_window_duration(_minutes), do: "n/a"

  defp format_reset_time(timestamp) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp, :second) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _error -> to_string(timestamp)
    end
  end

  defp format_reset_time(timestamp) when is_binary(timestamp), do: timestamp
  defp format_reset_time(_timestamp), do: "n/a"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp debug_value(debug, key, default) when is_map(debug), do: Map.get(debug, key) || Map.get(debug, to_string(key)) || default
  defp debug_value(_debug, _key, default), do: default
end

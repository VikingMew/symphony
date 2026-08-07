defmodule SymphonyElixir.Codex.RateLimitGate do
  @moduledoc """
  Decides whether a new Codex session may start from the latest parsed rate-limit snapshot.
  """

  alias SymphonyElixir.Payload

  @five_hour_mins 300
  @week_mins 10_080
  @default_5h_threshold 5.0
  @default_7d_threshold 3.0
  @default_post_reset_delay_ms 20 * 60 * 1_000

  @spec check(term(), term(), keyword()) :: :allow | {:block, map()}
  def check(snapshot, settings, opts \\ [])

  def check(snapshot, settings, opts) when is_map(snapshot) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    policy = policy(settings)

    if policy.enabled? do
      snapshot
      |> blocking_decisions(policy, now)
      |> Enum.sort_by(&block_sort_key/1)
      |> List.first()
      |> case do
        nil -> :allow
        decision -> {:block, decision}
      end
    else
      :allow
    end
  end

  def check(_snapshot, _settings, _opts), do: :allow

  @spec policy(term()) :: map()
  def policy(settings) do
    codex = codex_settings(settings)

    %{
      enabled?: bool(setting(codex, :rate_limit_gate_enabled), true),
      thresholds: %{
        @five_hour_mins => float(setting(codex, :rate_limit_gate_5h_threshold_percent), @default_5h_threshold),
        @week_mins => float(setting(codex, :rate_limit_gate_7d_threshold_percent), @default_7d_threshold)
      },
      post_reset_delay_ms: integer(setting(codex, :rate_limit_gate_post_reset_delay_ms), @default_post_reset_delay_ms)
    }
  end

  @spec window_duration_for(term()) :: integer() | nil
  def window_duration_for(label) when label in ["5h", :five_hour, :primary, "primary"], do: @five_hour_mins
  def window_duration_for(label) when label in ["7d", "1w", :seven_day, :week, :secondary, "secondary"], do: @week_mins
  def window_duration_for(minutes) when minutes in [@five_hour_mins, @week_mins], do: minutes
  def window_duration_for(_label), do: nil

  defp blocking_decisions(snapshot, policy, now) do
    snapshot
    |> buckets()
    |> Enum.flat_map(&blocking_decision(&1, policy, now))
  end

  defp buckets(snapshot) do
    [
      {"primary", Payload.get_any(snapshot, ["primary", :primary])},
      {"secondary", Payload.get_any(snapshot, ["secondary", :secondary])}
    ]
    |> Enum.filter(fn {_name, bucket} -> is_map(bucket) end)
  end

  defp blocking_decision({bucket_name, bucket}, policy, now) do
    duration = bucket |> Payload.get_any(["window_duration_mins", :window_duration_mins, "windowDurationMins", :windowDurationMins]) |> integer(nil)
    threshold = Map.get(policy.thresholds, duration)
    used_percent = bucket |> Payload.get_any(["used_percent", :used_percent, "usedPercent", :usedPercent]) |> float(nil)

    cond do
      is_nil(threshold) or is_nil(used_percent) ->
        []

      100.0 - used_percent >= threshold ->
        []

      true ->
        decision = block_details(bucket_name, bucket, duration, used_percent, threshold, policy.post_reset_delay_ms)

        if resume_elapsed?(decision, now) do
          []
        else
          [decision]
        end
    end
  end

  defp block_details(bucket_name, bucket, duration, used_percent, threshold, post_reset_delay_ms) do
    resets_at = reset_datetime(Payload.get_any(bucket, ["resets_at", :resets_at, "resetsAt", :resetsAt]))
    resume_after = resume_after(resets_at, post_reset_delay_ms)

    %{
      status: :blocked,
      reason: :low_rate_limit_headroom,
      window: window_label(duration),
      bucket: bucket_name,
      window_duration_mins: duration,
      used_percent: used_percent,
      remaining_percent: max(0.0, 100.0 - used_percent),
      threshold_percent: threshold,
      resets_at: resets_at,
      resume_after: resume_after,
      post_reset_delay_ms: post_reset_delay_ms
    }
  end

  defp resume_elapsed?(%{resume_after: %DateTime{} = resume_after}, %DateTime{} = now) do
    DateTime.compare(now, resume_after) != :lt
  end

  defp resume_elapsed?(_decision, _now), do: false

  defp block_sort_key(%{resume_after: %DateTime{} = resume_after}), do: DateTime.to_unix(resume_after, :millisecond)
  defp block_sort_key(_decision), do: -1

  defp resume_after(%DateTime{} = resets_at, post_reset_delay_ms) do
    DateTime.add(resets_at, post_reset_delay_ms, :millisecond)
  end

  defp resume_after(_resets_at, _post_reset_delay_ms), do: nil

  defp reset_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value, :second) do
      {:ok, datetime} -> datetime
      _error -> nil
    end
  end

  defp reset_datetime(value) when is_binary(value) do
    with {integer, ""} <- Integer.parse(value),
         {:ok, datetime} <- DateTime.from_unix(integer, :second) do
      datetime
    else
      _ -> nil
    end
  end

  defp reset_datetime(_value), do: nil

  defp window_label(@five_hour_mins), do: "5h"
  defp window_label(@week_mins), do: "1w"
  defp window_label(minutes), do: "#{minutes}m"

  defp codex_settings(%{codex: codex}), do: codex
  defp codex_settings(%{"codex" => codex}), do: codex
  defp codex_settings(codex), do: codex

  defp setting(settings, key) when is_map(settings) do
    case Map.fetch(settings, key) do
      {:ok, value} -> value
      :error -> Map.get(settings, to_string(key))
    end
  end

  defp setting(settings, key) do
    if function_exported?(settings.__struct__, :__schema__, 1), do: Map.get(settings, key), else: nil
  rescue
    _ -> nil
  end

  defp bool(nil, default), do: default
  defp bool(value, _default) when is_boolean(value), do: value
  defp bool(value, _default) when is_binary(value), do: String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  defp bool(_value, default), do: default

  defp integer(nil, default), do: default
  defp integer(value, _default) when is_integer(value), do: value
  defp integer(value, default) when is_binary(value), do: parse_number(value, default, &trunc/1)
  defp integer(value, _default) when is_float(value), do: trunc(value)
  defp integer(_value, default), do: default

  defp float(nil, default), do: default
  defp float(value, _default) when is_integer(value), do: value / 1
  defp float(value, _default) when is_float(value), do: value
  defp float(value, default) when is_binary(value), do: parse_number(value, default, & &1)
  defp float(_value, default), do: default

  defp parse_number(value, default, mapper) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> mapper.(number)
      _ -> default
    end
  end
end

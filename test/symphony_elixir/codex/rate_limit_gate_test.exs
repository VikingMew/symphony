defmodule SymphonyElixir.Codex.RateLimitGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.RateLimitGate
  alias SymphonyElixir.Config.Schema

  @now ~U[2026-05-23 00:00:00Z]

  test "blocks the 5-hour window below the default remaining threshold" do
    reset = DateTime.add(@now, 60, :second) |> DateTime.to_unix()

    assert {:block, details} =
             RateLimitGate.check(
               %{"primary" => %{"window_duration_mins" => 300, "used_percent" => 96, "resets_at" => reset}},
               %{},
               now: @now
             )

    assert details.window == "5h"
    assert details.remaining_percent == 4.0
    assert details.threshold_percent == 5.0
    assert details.resume_after == DateTime.add(DateTime.from_unix!(reset), 1_200_000, :millisecond)
  end

  test "blocks the 7-day window below the default remaining threshold" do
    reset = DateTime.add(@now, 60, :second) |> DateTime.to_unix()

    assert {:block, details} =
             RateLimitGate.check(
               %{"secondary" => %{"window_duration_mins" => 10_080, "used_percent" => 98, "resets_at" => reset}},
               %{},
               now: @now
             )

    assert details.window == "1w"
    assert details.remaining_percent == 2.0
    assert details.threshold_percent == 3.0
  end

  test "allows starts exactly at configured thresholds" do
    snapshot = %{
      "primary" => %{"window_duration_mins" => 300, "used_percent" => 95},
      "secondary" => %{"window_duration_mins" => 10_080, "used_percent" => 97}
    }

    assert :allow = RateLimitGate.check(snapshot, %{}, now: @now)
  end

  test "7d and 1w aliases map to the same long window" do
    assert RateLimitGate.window_duration_for("7d") == 10_080
    assert RateLimitGate.window_duration_for("1w") == 10_080
  end

  test "post reset delay keeps blocking until resume time and then allows" do
    reset_at = DateTime.add(@now, -60, :second)

    snapshot = %{
      "primary" => %{
        "window_duration_mins" => 300,
        "used_percent" => 99,
        "resets_at" => DateTime.to_unix(reset_at)
      }
    }

    settings = %{"codex" => %{"rate_limit_gate_post_reset_delay_ms" => 120_000}}

    assert {:block, details} = RateLimitGate.check(snapshot, settings, now: @now)
    assert details.resume_after == DateTime.add(reset_at, 120_000, :millisecond)

    assert :allow = RateLimitGate.check(snapshot, settings, now: DateTime.add(@now, 61, :second))
  end

  test "missing or unrecognized snapshots allow dispatch by default" do
    assert :allow = RateLimitGate.check(nil, %{}, now: @now)
    assert :allow = RateLimitGate.check(%{"credits" => %{}}, %{}, now: @now)
  end

  test "disabled gate allows dispatch for atom-keyed schema settings" do
    snapshot = %{"primary" => %{"window_duration_mins" => 300, "used_percent" => 100}}
    settings = %Schema.Codex{rate_limit_gate_enabled: false}

    assert :allow = RateLimitGate.check(snapshot, settings, now: @now)
  end

  test "custom thresholds from settings are applied" do
    settings = %{"codex" => %{"rate_limit_gate_5h_threshold_percent" => 10, "rate_limit_gate_7d_threshold_percent" => 20}}

    assert {:block, %{window: "5h", threshold_percent: 10.0}} =
             RateLimitGate.check(%{"primary" => %{"window_duration_mins" => 300, "used_percent" => 91}}, settings, now: @now)

    assert {:block, %{window: "1w", threshold_percent: 20.0}} =
             RateLimitGate.check(%{"secondary" => %{"window_duration_mins" => 10_080, "used_percent" => 81}}, settings, now: @now)
  end
end

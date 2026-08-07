defmodule SymphonyElixir.DashboardSignalTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Update
  alias SymphonyElixirWeb.{LinearStatusSignal, RateLimitStatus}

  test "rate-limit status distinguishes parsed nil and unrecognized states" do
    parsed =
      RateLimitStatus.from_snapshot(%{
        rate_limits: %{"limit_id" => "codex", "primary" => %{"remaining" => 7}},
        codex_totals: %{total_tokens: 12},
        running: []
      })

    assert parsed.status == :available
    assert parsed.snapshot["primary"]["remaining"] == 7

    missing = RateLimitStatus.from_snapshot(%{rate_limits: nil, codex_totals: %{total_tokens: 12}, running: []})
    assert missing.status == :not_received
    assert missing.note =~ "No upstream rate-limit snapshot"

    unrecognized =
      RateLimitStatus.from_snapshot(%{
        rate_limits: nil,
        rate_limit_observation: %{status: :unrecognized},
        codex_totals: %{total_tokens: 12},
        running: [%{last_codex_event: :notification, last_codex_timestamp: ~U[2026-05-21 00:00:00Z]}]
      })

    assert unrecognized.status == :unrecognized
    assert unrecognized.last_codex_event == :notification
  end

  test "rate-limit status exposes session start gate blocks" do
    blocked =
      RateLimitStatus.from_snapshot(%{
        rate_limits: %{"limit_id" => "codex"},
        rate_limit_gate: %{
          status: :blocked,
          window: "5h",
          remaining_percent: 2.5,
          threshold_percent: 5.0,
          resume_after: ~U[2026-05-23 01:20:00Z]
        }
      })

    assert blocked.status == :blocked
    assert blocked.note =~ "Dispatch paused"
    assert blocked.note =~ "5h"
    assert blocked.gate.window == "5h"
  end

  test "codex update detects rate-limit update events without parsed snapshots" do
    update = %{
      event: :notification,
      payload: %{"method" => "account/rateLimits/updated", "params" => %{"rateLimits" => [%{"unexpected" => true}]}},
      timestamp: DateTime.utc_now()
    }

    assert Update.rate_limit_update_event?(update)
    assert is_nil(Update.rate_limits(update))
  end

  test "observed codex rate-limit payload renders as a parsed snapshot" do
    raw = %{
      "credits" => nil,
      "limitId" => "codex",
      "limitName" => nil,
      "planType" => "pro",
      "primary" => %{"resetsAt" => 1_779_341_757, "usedPercent" => 65, "windowDurationMins" => 300},
      "rateLimitReachedType" => nil,
      "secondary" => %{"resetsAt" => 1_779_848_319, "usedPercent" => 18, "windowDurationMins" => 10_080}
    }

    parsed = Update.rate_limits(%{payload: %{"params" => %{"rateLimits" => [raw]}}})

    assert parsed["limit_id"] == "codex"
    assert parsed["plan_type"] == "pro"
    assert parsed["primary"]["used_percent"] == 65
    assert parsed["secondary"]["used_percent"] == 18

    status = RateLimitStatus.from_snapshot(%{rate_limits: parsed, codex_totals: %{}, running: []})

    assert status.status == :available
    refute status.status == :unrecognized
    assert status.debug_payload == nil
  end

  test "rate-limit debug payload captures bounded scrubbed unrecognized candidate data" do
    update = %{
      event: :notification,
      payload: %{
        "method" => "account/rateLimits/updated",
        "params" => %{
          "rateLimits" => [
            %{
              "unexpected" => true,
              "authorization" => "Bearer super-secret-token",
              "cookie" => "sid=super-secret-cookie",
              "api_key" => "super-secret-api-key",
              "body" => String.duplicate("x", 700)
            }
          ]
        }
      }
    }

    debug = Update.rate_limit_debug_payload(update)

    assert debug.source_path == "update.payload.params.rateLimits"
    assert debug.method == "account/rateLimits/updated"
    assert debug.truncated == true

    inspected = inspect(debug.payload)
    assert inspected =~ "[REDACTED]"
    assert inspected =~ "... (truncated)"
    refute inspected =~ "super-secret-token"
    refute inspected =~ "super-secret-cookie"
    refute inspected =~ "super-secret-api-key"

    status =
      RateLimitStatus.from_snapshot(%{
        rate_limits: nil,
        rate_limit_observation: %{status: :unrecognized, debug_payload: debug}
      })

    assert status.debug_payload == debug
  end

  test "linear signal summarizes unknown healthy and error diagnostics" do
    assert %{status: :unknown, href: "/diagnostics/linear"} = LinearStatusSignal.unknown()

    healthy =
      LinearStatusSignal.from_diagnostics(%{
        ran_at: ~U[2026-05-21 00:00:00Z],
        config: %{project_slug: "project"},
        probes: %{api: %{status: :ok}, project: %{status: :ok}, states: %{status: :ok}, candidates: %{status: :ok}},
        issues: [%{identifier: "CCR-1"}]
      })

    assert healthy.status == :ok
    assert healthy.candidate_count == 1
    assert healthy.project_slug == "project"

    error =
      LinearStatusSignal.from_diagnostics(%{
        config: %{project_slug: "project"},
        probes: %{api: %{status: :error, detail: "token is missing"}},
        issues: []
      })

    assert error.status == :error
    assert error.detail =~ "token is missing"
  end

  test "linear signal summarizes shared health stale and recent failed request states" do
    stale =
      LinearStatusSignal.from_health(%{
        status: :stale,
        display_status: :stale,
        label: "Linear stale",
        observed_at: ~U[2026-05-21 00:00:00Z],
        project_slug: "project",
        detail: "Latest Linear diagnostics did not report blocking issues.",
        display_detail: "Stale Linear health: Latest Linear diagnostics did not report blocking issues."
      })

    assert stale.status == :stale
    assert stale.badge_class =~ "warning"
    assert stale.detail =~ "Stale"

    warning =
      LinearStatusSignal.from_health(%{
        status: :ok,
        display_status: :warning,
        label: "Linear warning",
        observed_at: ~U[2026-05-21 00:00:00Z],
        project_slug: "project",
        detail: "Latest Linear diagnostics did not report blocking issues.",
        display_detail: "Linear candidate issue fetch failed: timeout",
        request: %{state: :failed, detail: "Linear candidate issue fetch failed: timeout"}
      })

    assert warning.status == :warning
    assert warning.detail =~ "candidate issue fetch failed"
  end
end

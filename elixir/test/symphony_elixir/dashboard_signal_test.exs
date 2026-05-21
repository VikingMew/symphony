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

  test "codex update detects rate-limit update events without parsed snapshots" do
    update = %{
      event: :notification,
      payload: %{"method" => "account/rateLimits/updated", "params" => %{"rateLimits" => [%{"unexpected" => true}]}},
      timestamp: DateTime.utc_now()
    }

    assert Update.rate_limit_update_event?(update)
    assert is_nil(Update.rate_limits(update))
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
end

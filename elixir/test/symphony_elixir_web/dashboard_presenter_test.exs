defmodule SymphonyElixirWeb.DashboardPresenterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.DashboardPresenter

  test "formats runtime, turns, integers, and timestamps" do
    now = ~U[2026-05-21 10:01:05Z]
    started_at = ~U[2026-05-21 10:00:00Z]

    assert DashboardPresenter.format_runtime_seconds(65) == "1m 5s"
    assert DashboardPresenter.format_runtime_and_turns(started_at, 3, now) == "1m 5s / 3"
    assert DashboardPresenter.format_runtime_and_turns(DateTime.to_iso8601(started_at), nil, now) == "1m 5s"
    assert DashboardPresenter.total_runtime_seconds(%{codex_totals: %{seconds_running: 30}, running: [%{started_at: started_at}]}, now) == 95
    assert DashboardPresenter.format_int(1_234_567) == "1,234,567"
    assert DashboardPresenter.format_int(nil) == "n/a"
    assert DashboardPresenter.format_time(now) == "2026-05-21T10:01:05Z"
  end

  test "returns dashboard badge classes and labels" do
    assert DashboardPresenter.rate_limit_status_label(:available) == "available"
    assert DashboardPresenter.rate_limit_status_label(:blocked) == "paused"
    assert DashboardPresenter.rate_limit_status_label(:unrecognized) == "unrecognized"
    assert DashboardPresenter.rate_limit_status_label(:missing) == "not received"

    assert DashboardPresenter.rate_limit_badge_class(:available) == "status-badge status-success"
    assert DashboardPresenter.rate_limit_badge_class(:blocked) == "status-badge status-danger"
    assert DashboardPresenter.rate_limit_badge_class(:unrecognized) == "status-badge status-warning"
    assert DashboardPresenter.rate_limit_badge_class(nil) == "status-badge status-info"

    assert DashboardPresenter.state_badge_class("In Progress") =~ "state-badge-active"
    assert DashboardPresenter.state_badge_class("failed") =~ "state-badge-danger"
    assert DashboardPresenter.state_badge_class("queued") =~ "state-badge-warning"

    assert DashboardPresenter.listening_enabled?(%{polling: %{listening?: true}})
    assert DashboardPresenter.listening_label(%{polling: %{listening_mode: "listening_all"}}) == "all active work"
    assert DashboardPresenter.listening_label(%{polling: %{listening_mode: "listening_refine_only"}}) == "refinement only"
    assert DashboardPresenter.listening_badge_class(%{polling: %{listening_mode: "listening_refine_only"}}) == "status-badge status-warning"
    assert DashboardPresenter.listening_badge_class(%{polling: %{listening?: false}}) == "status-badge status-danger"
  end

  test "formats session history keys summaries and source badges" do
    entry = %{
      issue_id: nil,
      issue_identifier: "CCR-5",
      session_id: "session-1",
      session_history: [%{event: "started"}, %{event: "finished"}],
      session_history_total_count: 5
    }

    assert DashboardPresenter.session_history_key(entry) == "CCR-5"
    refute DashboardPresenter.session_history_expanded?(MapSet.new(), entry)
    assert DashboardPresenter.session_history_expanded?(MapSet.new(["CCR-5"]), entry)
    assert DashboardPresenter.session_history_summary(entry) == "Session history (2 rows from 5 events)"

    assert DashboardPresenter.toggle_session_history_key(MapSet.new(), "CCR-5") == MapSet.new(["CCR-5"])
    assert DashboardPresenter.toggle_session_history_key(MapSet.new(["CCR-5"]), "CCR-5") == MapSet.new()

    assert DashboardPresenter.history_badge_class(:error) == "status-badge status-danger"
    assert DashboardPresenter.history_source_badge_class(:linear) == "status-badge status-accent"
    assert DashboardPresenter.history_source_label(:system_event) == "system event"
  end

  test "formats rate-limit debug payload fields and truncates long payloads" do
    debug = %{
      "source_path" => "root.rateLimits",
      method: "extract",
      reason: "unknown shape",
      truncated: true,
      payload: String.duplicate("x", 2_100)
    }

    assert DashboardPresenter.rate_limit_debug_source(debug) == "root.rateLimits"
    assert DashboardPresenter.rate_limit_debug_method(debug) == "extract"
    assert DashboardPresenter.rate_limit_debug_reason(debug) == "unknown shape"
    assert DashboardPresenter.rate_limit_debug_truncated?(debug)
    assert DashboardPresenter.rate_limit_debug_payload(debug) =~ "... (truncated)"
    assert DashboardPresenter.pretty_value(nil) == "n/a"
    assert DashboardPresenter.truncate_string("abcdef", 3) == "abc... (truncated)"
  end

  test "formats parsed codex rate-limit plan and bucket summaries" do
    snapshot = %{
      "limit_id" => "codex",
      "plan_type" => "pro",
      "primary" => %{"used_percent" => 65, "window_duration_mins" => 300, "resets_at" => 1_779_341_757},
      "secondary" => %{"used_percent" => 18, "window_duration_mins" => 10_080, "resets_at" => 1_779_848_319}
    }

    assert DashboardPresenter.rate_limit_plan_context(snapshot) == "Plan pro · Limit codex"

    assert [
             %{label: "Primary", used_percent: 65, window_duration: "5h", resets_at: "2026-05-21T05:35:57Z"},
             %{label: "Secondary", used_percent: 18, window_duration: "1w", resets_at: "2026-05-27T02:18:39Z"}
           ] = DashboardPresenter.rate_limit_bucket_summaries(snapshot)
  end
end

defmodule SymphonyElixirWeb.Admin.ObservabilityPresenterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  test "formats durations and timestamps" do
    assert ObservabilityPresenter.fmt_dt(~U[2026-05-21 00:00:00Z]) == "2026-05-21T00:00:00Z"
    assert ObservabilityPresenter.fmt_dt(nil) == "n/a"
    assert ObservabilityPresenter.fmt_duration(~U[2026-05-21 00:00:00Z], ~U[2026-05-21 00:01:05Z]) == "1m 5s"
    assert ObservabilityPresenter.fmt_duration(nil, nil) == "running"
  end

  test "scrubs sensitive event payload values" do
    text = ObservabilityPresenter.safe_event_payload(%{"api_token" => "secret", "nested" => %{"cookie" => "cookie", "ok" => "value"}})

    assert text =~ "[REDACTED]"
    assert text =~ "value"
    refute text =~ "secret"
    refute text =~ "cookie\" => \"cookie"
  end

  test "formats status classes and worker empty states" do
    assert ObservabilityPresenter.status_class("completed") == "status-badge status-success"
    assert ObservabilityPresenter.status_class("failed") == "status-badge status-danger"
    assert ObservabilityPresenter.status_class("other") == "status-badge"
    assert ObservabilityPresenter.worker_empty_message(:centralized) =~ "Centralized execution"
  end
end

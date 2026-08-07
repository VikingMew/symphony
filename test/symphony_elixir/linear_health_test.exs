defmodule SymphonyElixir.LinearHealthTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Health
  alias SymphonyElixirWeb.LinearStatusSignal

  test "starts unknown before any shared Linear observation completes" do
    assert %{status: :unknown} = Health.latest()
    assert %{status: :unknown, label: "Linear unknown"} = Health.latest() |> LinearStatusSignal.from_health()
  end

  test "records diagnostics readiness and dashboard signal consumes it" do
    Health.observe_diagnostics(%{
      run_id: "linear-diagnostics-test",
      ran_at: ~U[2026-05-21 00:00:00Z],
      config: %{project_slug: "project"},
      probes: %{api: %{status: :ok}, project: %{status: :ok}, states: %{status: :ok}, candidates: %{status: :ok}},
      issues: [%{identifier: "CCR-1"}]
    })

    health = Health.latest(now: ~U[2026-05-21 00:01:00Z])
    assert health.status == :ok
    assert health.source == :diagnostics
    assert health.project_slug == "project"
    assert health.candidate_count == 1
    assert health.display_status == :ok
    assert health.label == "Linear ok"
    assert health.display_detail =~ "did not report blocking issues"

    signal = LinearStatusSignal.from_health(health)
    assert signal.status == :ok
    assert signal.label == "Linear ok"
    assert signal.project_slug == "project"
    assert signal.candidate_count == 1
  end

  test "records diagnostics error without leaking secret values" do
    Health.observe_diagnostics(%{
      ran_at: ~U[2026-05-21 00:00:00Z],
      config: %{project_slug: "project"},
      probes: %{api: %{status: :error, detail: "Authorization Bearer secret-token failed"}},
      issues: []
    })

    health = Health.latest(now: ~U[2026-05-21 00:01:00Z])
    signal = LinearStatusSignal.from_health(health)

    assert signal.status == :error
    assert signal.detail =~ "API:"
    refute inspect(signal) =~ "secret-token"
  end

  test "records routine polling success and failed request without losing prior conclusion" do
    Health.observe_runtime_request(:candidate_fetch, {:ok, [%{identifier: "CCR-1"}, %{identifier: "CCR-2"}]})

    ready = Health.latest()
    assert ready.status == :ok
    assert ready.source == :candidate_fetch
    assert ready.candidate_count == 2

    Health.observe_runtime_request(:candidate_fetch, {:error, {:linear_api_status, 500, %{token: "secret-token"}}})

    health = Health.latest()
    assert health.status == :ok
    assert health.request.state == :failed
    assert health.display_status == :warning
    assert health.display_detail =~ "candidate issue fetch failed"

    signal = LinearStatusSignal.from_health(health)
    assert signal.status == :warning
    assert signal.detail =~ "candidate issue fetch failed"
    refute signal.detail =~ "secret-token"
  end

  test "marks old conclusions stale without deleting observation time" do
    Health.observe_diagnostics(%{
      ran_at: ~U[2026-05-21 00:00:00Z],
      config: %{project_slug: "project"},
      probes: %{api: %{status: :ok}},
      issues: []
    })

    health = Health.latest(now: ~U[2026-05-21 00:20:00Z], ttl_ms: :timer.minutes(5))
    signal = LinearStatusSignal.from_health(health)

    assert health.status == :stale
    assert signal.status == :stale
    assert signal.ran_at == ~U[2026-05-21 00:00:00Z]
    assert signal.detail =~ "Stale"
  end
end

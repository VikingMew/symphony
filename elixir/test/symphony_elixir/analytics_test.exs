defmodule SymphonyElixir.AnalyticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Analytics
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)

    on_exit(fn -> restore_app_env(:persistence_module, previous_persistence) end)

    :ok
  end

  test "aggregates run status, project, retry, blocked, duration, and token metrics" do
    now = ~U[2026-05-21 00:00:00Z]
    old = ~U[2026-05-10 00:00:00Z]

    FakePersistence.put_runs([
      run("run-1", "CCR-1", "completed", DateTime.add(now, -120, :second), now),
      run("run-2", "CCR-2", "failed", DateTime.add(now, -60, :second), now, "workspace timeout"),
      run("run-3", "CCR-3", "blocked", now, nil),
      run("run-old", "CCR-OLD", "completed", old, old)
    ])

    FakePersistence.put_events([
      %{event_type: "run.retry_scheduled", occurred_at: now, payload: %{}, issue_identifier: "CCR-2"},
      %{event_type: "codex.update", occurred_at: now, payload: %{"tokens" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}}},
      %{event_type: "run.retry_scheduled", occurred_at: old, payload: %{}}
    ])

    summary = Analytics.summary(range: "7d", now: now)

    assert summary.total_runs == 3
    assert row(summary.status_rows, "completed").count == 1
    assert row(summary.status_rows, "failed").count == 1
    assert row(summary.status_rows, "blocked").count == 1
    assert row(summary.project_rows, "Fake Project").count == 3
    assert row(summary.issue_rows, "CCR-1").href == "/issues/CCR-1"
    assert summary.retry_count == 1
    assert summary.blocked_count == 1
    assert summary.duration.average_seconds == 90
    assert summary.duration.p50_seconds == 60
    assert summary.duration.p95_seconds == 120
    assert summary.tokens == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
  end

  test "empty ranges are stable" do
    now = ~U[2026-05-21 00:00:00Z]
    FakePersistence.put_runs([])
    FakePersistence.put_events([])

    summary = Analytics.summary(range: "24h", now: now)

    assert summary.total_runs == 0
    assert summary.status_rows == []
    assert summary.duration.average_seconds == 0
    assert summary.tokens.total_tokens == 0
  end

  defp run(id, issue_identifier, status, started_at, finished_at, failure_reason \\ nil) do
    %{
      id: id,
      project_id: "fake-project-id",
      issue_identifier: issue_identifier,
      execution_mode: "centralized",
      status: status,
      attempt: 1,
      failure_reason: failure_reason,
      started_at: started_at,
      finished_at: finished_at
    }
  end

  defp row(rows, key), do: Enum.find(rows, &(&1.key == key))

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

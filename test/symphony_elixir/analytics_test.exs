defmodule SymphonyElixir.AnalyticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Analytics
  alias SymphonyElixir.TestSupport.FakePersistence

  defmodule FaultPersistence do
    @moduledoc false

    def list_runs(_opts), do: read(:runs)
    def list_events(_opts), do: read(:events)
    def list_projects, do: read(:projects)

    defp read(name) do
      if Application.get_env(:symphony_elixir, :analytics_fault_reader) == name do
        raise "#{name} query failed"
      else
        []
      end
    end
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.delete_env(:symphony_elixir, :analytics_fault_reader)
    end)

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

    assert summary.status == :available
    assert summary.total_runs == 0
    assert summary.status_rows == []
    assert summary.duration.average_seconds == 0
    assert summary.tokens.total_tokens == 0

    assert summary.refinement_description == %{
             samples: 0,
             average_characters: 0.0,
             average_lines: 0.0,
             p95_characters: 0,
             p95_lines: 0,
             over_limit: 0,
             over_rate: 0.0
           }
  end

  test "aggregates refinement description measurements within the selected range" do
    now = ~U[2026-05-21 00:00:00Z]

    FakePersistence.put_events([
      measurement_event(now, 10, 2, false),
      measurement_event(now, 20, 4, true),
      measurement_event(now, 30, 6, true),
      measurement_event(DateTime.add(now, -8, :day), 1_000, 1_000, true)
    ])

    summary = Analytics.summary(range: "7d", now: now).refinement_description

    assert summary.samples == 3
    assert summary.average_characters == 20.0
    assert summary.average_lines == 4.0
    assert summary.p95_characters == 30
    assert summary.p95_lines == 6
    assert summary.over_limit == 2
    assert_in_delta summary.over_rate, 2 / 3, 0.0001
  end

  test "extracts realistic codex token payload shapes without double-counting run cumulative snapshots" do
    now = ~U[2026-05-21 00:00:00Z]

    FakePersistence.put_runs([
      run("run-token-1", "CCR-1", "completed", DateTime.add(now, -30, :second), now),
      run("run-token-2", "CCR-2", "completed", DateTime.add(now, -20, :second), now)
    ])

    FakePersistence.put_events([
      %{
        run_id: "run-token-1",
        event_type: "codex.update",
        occurred_at: now,
        payload: %{"params" => %{"tokenUsage" => %{"total" => %{"input_tokens" => 6, "output_tokens" => 4, "total_tokens" => 10}}}}
      },
      %{
        run_id: "run-token-1",
        event_type: "codex.update",
        occurred_at: now,
        payload: %{"params" => %{"tokenUsage" => %{"total" => %{"input_tokens" => 9, "output_tokens" => 6, "total_tokens" => 15}}}}
      },
      %{
        run_id: "run-token-2",
        event_type: "codex.update",
        occurred_at: now,
        payload: %{
          "params" => %{
            "msg" => %{
              "payload" => %{
                "info" => %{
                  "total_token_usage" => %{"input_tokens" => 20, "output_tokens" => 5, "total_tokens" => 25}
                }
              }
            }
          }
        }
      }
    ])

    summary = Analytics.summary(range: "7d", now: now)

    assert summary.tokens == %{input_tokens: 29, output_tokens: 11, total_tokens: 40}
  end

  test "surfaces each failed persistence reader as unavailable instead of zero analytics" do
    Enum.each([:runs, :events, :projects], fn reader ->
      Application.put_env(:symphony_elixir, :analytics_fault_reader, reader)

      assert %{
               status: :unavailable,
               error: {:query_failed, %RuntimeError{message: message}}
             } = Analytics.summary(persistence: FaultPersistence)

      assert message == "#{reader} query failed"
    end)
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

  defp measurement_event(occurred_at, characters, lines, over_limit) do
    %{
      event_type: "refinement.description_measurement",
      occurred_at: occurred_at,
      payload: %{characters: characters, lines: lines, over_limit: over_limit}
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

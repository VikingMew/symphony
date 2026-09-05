defmodule SymphonyElixirWeb.AnalyticsLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "renders empty analytics page without live orchestrator state" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "Analytics"
    assert html =~ "No persisted analytics data for this range."
    assert html =~ "Last 7 days"
  end

  test "renders persisted run and event aggregates" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    now = DateTime.utc_now()

    FakePersistence.put_runs([
      %{
        id: "run-analytics-1",
        project_id: "fake-project-id",
        issue_identifier: "CCR-5",
        status: "completed",
        execution_mode: "centralized",
        attempt: 1,
        started_at: DateTime.add(now, -120, :second),
        finished_at: now
      }
    ])

    FakePersistence.put_events([
      %{
        event_type: "codex.update",
        issue_identifier: "CCR-5",
        run_id: "run-analytics-1",
        occurred_at: now,
        payload: %{
          "params" => %{
            "msg" => %{
              "payload" => %{
                "info" => %{
                  "total_token_usage" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
                }
              }
            }
          }
        }
      },
      %{
        event_type: "refinement.description_measurement",
        issue_identifier: "CCR-5",
        occurred_at: now,
        payload: %{characters: 800, lines: 40, over_limit: true}
      }
    ])

    {:ok, _view, html} = live(build_conn(), "/analytics?range=24h")

    assert html =~ "Last 24 hours"
    assert html =~ "Fake Project"
    assert html =~ "CCR-5"
    assert html =~ "completed"
    assert html =~ "Total tokens"
    assert html =~ "12"
    assert html =~ "Refinement description"
    assert html =~ "1 samples"
    assert html =~ "over limit 1 (100.0%)"
    assert html =~ ~s(href="/issues/CCR-5")

    document = Floki.parse_document!(html)

    status_headers = table_headers(document, "Status")
    assert status_headers == ["Name", "Runs"]

    project_headers = table_headers(document, "Projects")
    assert project_headers == ["Name", "Runs", "Completed", "Failed", "Blocked"]
  end

  test "renders data unavailable instead of zero metrics when persistence is down" do
    refute Process.whereis(SymphonyElixir.Repo)
    Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.Persistence)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "Data unavailable"
    refute html =~ "No persisted analytics data for this range."
    refute html =~ "Persisted runs in range"
  end

  defp table_headers(document, title) do
    document
    |> Floki.find("section.section-card")
    |> Enum.find(fn section ->
      section
      |> Floki.find("h2")
      |> Floki.text()
      |> String.trim() == title
    end)
    |> Floki.find("thead th")
    |> Enum.map(fn th -> th |> Floki.text() |> String.trim() end)
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

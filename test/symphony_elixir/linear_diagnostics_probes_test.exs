defmodule SymphonyElixir.LinearDiagnosticsProbesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Diagnostics.Probes
  alias SymphonyElixir.Linear.Issue

  defmodule FakeClient do
    @moduledoc false

    def graphql(_query, variables, opts) do
      fake = Application.get_env(:symphony_elixir, :linear_diagnostics_probe_fake, %{})

      case Map.get(fake, Keyword.fetch!(opts, :operation_name)) do
        nil -> {:ok, default_response(Keyword.fetch!(opts, :operation_name), variables)}
        {:error, reason} -> {:error, reason}
        response when is_function(response, 1) -> {:ok, response.(variables)}
        response -> {:ok, response}
      end
    end

    def fetch_candidate_issues do
      fake = Application.get_env(:symphony_elixir, :linear_diagnostics_probe_fake, %{})
      Map.get(fake, :candidate_result, {:ok, []})
    end

    defp default_response("SymphonyLinearDiagnosticsViewer", _variables) do
      %{"data" => %{"viewer" => %{"id" => "viewer-1", "name" => "Operator", "email" => "operator@example.test"}}}
    end

    defp default_response("SymphonyLinearDiagnosticsTeams", _variables) do
      %{"data" => %{"teams" => %{"nodes" => [%{"id" => "team-1", "name" => "Platform"}, :bad_team]}}}
    end

    defp default_response("SymphonyLinearDiagnosticsProject", _variables) do
      %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{
                "id" => "project-1",
                "name" => "Project",
                "slugId" => "project",
                "url" => "https://linear.app/project/project",
                "teams" => %{
                  "nodes" => [
                    %{
                      "id" => "team-1",
                      "name" => "Platform",
                      "states" => %{"nodes" => [%{"name" => "Ready"}, %{"name" => "Done"}, %{"name" => ""}]}
                    }
                  ]
                }
              }
            ]
          }
        }
      }
    end
  end

  setup do
    previous_fake = Application.get_env(:symphony_elixir, :linear_diagnostics_probe_fake)

    on_exit(fn ->
      restore_app_env(:linear_diagnostics_probe_fake, previous_fake)
    end)
  end

  test "api and teams probes normalize successful GraphQL payloads" do
    assert %{status: :ok, data: %{viewer: %{id: "viewer-1", name: "Operator"}}} = Probes.api_probe(FakeClient)

    assert %{status: :ok, data: %{team_count: 2, teams: teams}} = Probes.teams_probe(FakeClient)
    assert %{id: "team-1", name: "Platform"} in teams
    assert %{id: "n/a", name: "n/a"} in teams
  end

  test "project and states probes expose normalized project state names" do
    project_probe = Probes.project_probe(FakeClient, "project")

    assert project_probe.status == :ok
    assert project_probe.data.project.slug == "project"
    assert project_probe.data.state_names == ["Done", "Ready"]

    assert %{status: :ok, detail: "All configured workflow states exist in Linear."} =
             Probes.states_probe(project_probe, settings(active_states: ["Ready"], terminal_states: ["Done"]))
  end

  test "states probe reports missing configured state references and skipped project dependencies" do
    project_probe = Probes.project_probe(FakeClient, "project")

    failed = Probes.states_probe(project_probe, settings(active_states: ["Ready", "Missing"], terminal_states: ["Done"]))
    assert failed.status == :error
    assert failed.detail =~ "Missing Linear states: Missing"
    assert failed.data.missing_active == ["Missing"]

    skipped = Probes.states_probe(%{status: :error, data: %{}}, settings())
    assert skipped.status == :skipped
    assert skipped.detail =~ "project slug did not resolve"
  end

  test "candidate probe normalizes issue summaries and failure details" do
    issue = %Issue{
      identifier: "LIN-1",
      title: "Build it",
      state: "Ready",
      assignee_id: nil,
      labels: ["backend"],
      blocked_by: [%{identifier: "LIN-0"}],
      updated_at: ~U[2026-05-01 10:00:00Z],
      url: "https://linear.app/issue/LIN-1"
    }

    Application.put_env(:symphony_elixir, :linear_diagnostics_probe_fake, %{
      candidate_result: {:ok, [issue, %{identifier: "LIN-2"}]}
    })

    assert {%{status: :ok, data: %{issue_count: 2}}, issues} = Probes.candidate_probe(FakeClient)
    assert [%{identifier: "LIN-1", assignee: "unassigned"}, %{identifier: "LIN-2"}] = issues

    Application.put_env(:symphony_elixir, :linear_diagnostics_probe_fake, %{
      candidate_result: {:error, {:token, "secret-token"}}
    })

    assert {%{status: :error, detail: detail}, []} = Probes.candidate_probe(FakeClient)
    assert detail =~ "[REDACTED]"
    refute detail =~ "secret-token"
  end

  test "graphql errors are normalized without leaking extensions" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_probe_fake, %{
      "SymphonyLinearDiagnosticsViewer" => %{
        "errors" => [%{"message" => "bad query", "extensions" => %{"token" => "secret"}}]
      }
    })

    assert %{status: :error, data: %{errors: [%{"message" => "bad query"}]}} = Probes.api_probe(FakeClient)
  end

  defp settings(opts \\ []) do
    tracker = %Schema.Tracker{
      kind: "linear",
      endpoint: "https://api.linear.app/graphql",
      api_key: "token",
      project_slug: "project",
      active_states: Keyword.get(opts, :active_states, ["Ready"]),
      terminal_states: Keyword.get(opts, :terminal_states, ["Done"])
    }

    %Schema{
      tracker: tracker,
      workflow: %{"states" => %{}, "human_review_states" => []},
      profiles: %{}
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

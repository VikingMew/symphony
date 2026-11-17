defmodule SymphonyElixir.ObservabilityHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ObservabilityHistory

  defmodule EdgePersistence do
    def get_issue_by_identifier(_identifier), do: response(:history_issue_response)
    def list_runs_for_issue(_identifier, _opts), do: response(:history_runs_response)
    def list_events(_opts), do: response(:history_events_response)

    defdelegate default_project(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate instance_workflow(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_projects(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate current_workflow(project), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate workflow_to_loaded(instance, version), to: SymphonyElixir.TestSupport.FakePersistence

    defp response(key), do: Application.fetch_env!(:symphony_elixir, key)
  end

  defmodule ExitPersistence do
    def get_issue_by_identifier(_identifier), do: Process.exit(self(), :kill)

    defdelegate default_project(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate instance_workflow(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_projects(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate current_workflow(project), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate workflow_to_loaded(instance, version), to: SymphonyElixir.TestSupport.FakePersistence
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.delete_env(:symphony_elixir, :history_issue_response)
      Application.delete_env(:symphony_elixir, :history_runs_response)
      Application.delete_env(:symphony_elixir, :history_events_response)
    end)

    :ok
  end

  test "parses default, integer, clamped, and invalid limits" do
    assert {:ok, 20} = ObservabilityHistory.parse_limit(nil)
    assert {:ok, 7} = ObservabilityHistory.parse_limit(7)
    assert {:ok, 50} = ObservabilityHistory.parse_limit(999)
    assert {:error, :invalid_limit} = ObservabilityHistory.parse_limit("")
    assert {:error, :invalid_limit} = ObservabilityHistory.parse_limit(0)
  end

  test "normalizes persistence list failures and task exits" do
    Application.put_env(:symphony_elixir, :persistence_module, EdgePersistence)
    Application.put_env(:symphony_elixir, :history_issue_response, nil)
    Application.put_env(:symphony_elixir, :history_events_response, [])

    Application.put_env(:symphony_elixir, :history_runs_response, {:error, :repo_unavailable})
    assert {:error, :repo_unavailable} = ObservabilityHistory.fetch("SYM-EDGE")

    Application.put_env(:symphony_elixir, :history_runs_response, {:error, {:query_failed, :busy}})
    assert {:error, {:query_failed, :busy}} = ObservabilityHistory.fetch("SYM-EDGE")

    Application.put_env(:symphony_elixir, :history_runs_response, :invalid)

    assert {:error, {:query_failed, {:invalid_persistence_result, :invalid}}} =
             ObservabilityHistory.fetch("SYM-EDGE")

    Application.put_env(:symphony_elixir, :persistence_module, ExitPersistence)
    assert {:error, {:query_failed, :killed}} = ObservabilityHistory.fetch("SYM-EDGE")
  end

  test "serializes and sorts naive, ISO-8601, invalid, and absent timestamps" do
    Application.put_env(:symphony_elixir, :persistence_module, EdgePersistence)
    Application.put_env(:symphony_elixir, :history_issue_response, issue())
    Application.put_env(:symphony_elixir, :history_runs_response, runs())
    Application.put_env(:symphony_elixir, :history_events_response, [])

    assert {:ok, history} = ObservabilityHistory.fetch("SYM-DATES")
    assert Enum.take(Enum.map(history.runs, & &1.id), 2) == ["naive", "iso"]
    assert MapSet.new(Enum.drop(Enum.map(history.runs, & &1.id), 2)) == MapSet.new(["invalid", "absent"])
    assert history.issue.updated_at == "2026-08-27T08:00:00Z"
    assert Enum.at(history.runs, 0).started_at == "2026-08-27T08:04:00Z"
    assert Enum.at(history.runs, 1).started_at == "2026-08-27T08:03:00Z"
    assert Enum.find(history.runs, &(&1.id == "absent")).started_at == nil
  end

  test "serializes recorded routing and run evidence without trusting legacy defaults" do
    Application.put_env(:symphony_elixir, :persistence_module, EdgePersistence)
    now = ~U[2026-11-10 05:00:30Z]

    snapshot = %{
      "state" => "Ready",
      "execution_requirement" => "host_only",
      "required_capabilities" => ["gui-session"],
      "routing_status" => "waiting_for_probe",
      "routing_reason" => "capability_mismatch",
      "eligible_probe_count" => 0,
      "selected_probe_id" => nil,
      "routing_since_at" => "2026-11-10T05:00:00Z"
    }

    Application.put_env(:symphony_elixir, :history_issue_response, Map.put(issue(), :snapshot, snapshot))

    recorded =
      run("recorded", now)
      |> Map.merge(%{
        execution_evidence_recorded: true,
        execution_requirement: "host_only",
        execution_surface: "host_probe",
        probe_id: "local-host",
        worker_session_id: "session-1"
      })

    legacy =
      run("legacy", DateTime.add(now, -1, :second))
      |> Map.merge(%{execution_requirement: "default", execution_surface: "panel"})

    Application.put_env(:symphony_elixir, :history_runs_response, [legacy, recorded])
    Application.put_env(:symphony_elixir, :history_events_response, [])

    assert {:ok, history} = ObservabilityHistory.fetch("SYM-DATES", now: now)
    assert history.issue.execution_requirement == "host_only"
    assert history.issue.required_capabilities == ["gui-session"]
    assert history.issue.routing_wait_seconds == 30
    assert history.issue.routing_alert

    assert history.latest_run.execution_surface == "host_probe"
    assert history.latest_run.execution_evidence_recorded

    projected_legacy = Enum.find(history.runs, &(&1.id == "legacy"))
    assert projected_legacy.execution_surface == "unrecorded"
    assert projected_legacy.execution_requirement == "unrecorded"
    refute projected_legacy.execution_evidence_recorded
  end

  test "serializes historical issue routing as unrecorded" do
    Application.put_env(:symphony_elixir, :persistence_module, EdgePersistence)
    Application.put_env(:symphony_elixir, :history_issue_response, Map.put(issue(), :snapshot, %{"state" => "Ready"}))
    Application.put_env(:symphony_elixir, :history_runs_response, [])
    Application.put_env(:symphony_elixir, :history_events_response, [])

    assert {:ok, history} = ObservabilityHistory.fetch("SYM-DATES", now: ~U[2026-11-10 05:00:00Z])
    assert history.issue.execution_requirement == "unrecorded"
    assert history.issue.required_capabilities == "unrecorded"
    assert history.issue.routing_status == "unrecorded"
    refute history.issue.routing_alert
  end

  defp issue do
    %{id: "issue-dates", identifier: "SYM-DATES", updated_at: ~N[2026-08-27 08:00:00]}
  end

  defp runs do
    [
      run("absent", nil),
      run("invalid", "not-a-timestamp"),
      run("iso", "2026-08-27T08:03:00Z"),
      run("naive", ~N[2026-08-27 08:04:00])
    ]
  end

  defp run(id, started_at) do
    %{
      id: id,
      kind: "issue",
      profile: "implementation",
      status: "completed",
      attempt: 1,
      started_at: started_at,
      finished_at: started_at,
      failure_reason: nil
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

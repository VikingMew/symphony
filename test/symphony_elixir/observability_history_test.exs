defmodule SymphonyElixir.ObservabilityHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ObservabilityHistory

  defmodule EdgePersistence do
    def get_issue_by_identifier(_identifier), do: response(:history_issue_response)
    def list_runs_for_issue(_identifier, _opts), do: response(:history_runs_response)
    def list_events(_opts), do: response(:history_events_response)

    defdelegate default_project(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_projects(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate active_workflow_version(project), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate workflow_to_loaded(version), to: SymphonyElixir.TestSupport.FakePersistence

    defp response(key), do: Application.fetch_env!(:symphony_elixir, key)
  end

  defmodule ExitPersistence do
    def get_issue_by_identifier(_identifier), do: Process.exit(self(), :kill)

    defdelegate default_project(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_projects(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate active_workflow_version(project), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate workflow_to_loaded(version), to: SymphonyElixir.TestSupport.FakePersistence
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

defmodule SymphonyElixir.OrchestratorRateLimitGateTest do
  use SymphonyElixir.TestSupport

  defmodule NotifyingLinearClient do
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def fetch_candidate_issues do
      send(test_pid(), :fetch_candidate_issues_called)
      {:ok, []}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :rate_limit_gate_test_pid)
  end

  setup do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_test_pid = Application.get_env(:symphony_elixir, :rate_limit_gate_test_pid)

    Application.put_env(:symphony_elixir, :linear_client_module, NotifyingLinearClient)
    Application.put_env(:symphony_elixir, :rate_limit_gate_test_pid, self())

    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: "git@example.test:repo.git")

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:rate_limit_gate_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "dispatch does not fetch or start work while the rate-limit gate is blocked" do
    orchestrator_name = Module.concat(__MODULE__, :BlockedDispatch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | listening?: true,
          listening_mode: :listening_all,
          codex_rate_limits: %{
            "primary" => %{
              "window_duration_mins" => 300,
              "used_percent" => 99,
              "resets_at" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()
            }
          }
      }
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(50)

    refute_receive :fetch_candidate_issues_called, 100

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.running == []
    assert snapshot.rate_limit_gate.status == :blocked
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

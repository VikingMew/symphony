defmodule SymphonyElixir.OrchestratorEnvironmentFailureCircuitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.EnvironmentFailureCircuit

  defmodule LinearClient do
    def fetch_candidate_issues do
      send(test_pid(), :fetch_candidate_issues_called)
      {:ok, []}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :environment_failure_circuit_test_pid)
  end

  test "docs/spec-reliability-security.md §14.5: open circuit pauses central candidate fetch until reset" do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_test_pid = Application.get_env(:symphony_elixir, :environment_failure_circuit_test_pid)

    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: "git@example.com:org/repo.git")
    Application.put_env(:symphony_elixir, :linear_client_module, LinearClient)
    Application.put_env(:symphony_elixir, :environment_failure_circuit_test_pid, self())

    Enum.each(1..EnvironmentFailureCircuit.threshold(), fn number ->
      EnvironmentFailureCircuit.record_failure(
        "SYM-#{number}",
        "bwrap: No permissions to create a new namespace",
        %{}
      )
    end)

    orchestrator_name = Module.concat(__MODULE__, :CentralDispatchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:environment_failure_circuit_test_pid, previous_test_pid)

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, &%{&1 | listening_mode: :listening_all})
    send(pid, :run_poll_cycle)
    refute_receive :fetch_candidate_issues_called, 100

    assert %{environment_failure_circuit: %{active: true}} = GenServer.call(pid, :snapshot)

    assert %{environment_failure_circuit: %{active: false}} =
             Orchestrator.reset_environment_failure_circuit(orchestrator_name)

    send(pid, :run_poll_cycle)
    assert_receive :fetch_candidate_issues_called, 100
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

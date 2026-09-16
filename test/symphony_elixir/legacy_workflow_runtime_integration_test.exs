defmodule SymphonyElixir.LegacyWorkflowRuntimeIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.LegacyWorkflowConvergence
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{Orchestrator, Workflow, WorkflowStore}
  alias SymphonyElixir.TestSupport.FakePersistence

  defmodule ReconciliationLinearClient do
    def fetch_candidate_issues do
      send(test_pid(), :candidate_fetch)
      {:ok, Application.get_env(:symphony_elixir, :legacy_reconciliation_candidates, [])}
    end

    def fetch_issue_states_by_ids(ids) do
      candidates = Application.get_env(:symphony_elixir, :legacy_reconciliation_candidates, [])
      {:ok, Enum.filter(candidates, &(&1.id in ids))}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}
    def graphql(_query, _variables), do: {:ok, %{"data" => %{}}}

    defp test_pid, do: Application.fetch_env!(:symphony_elixir, :legacy_reconciliation_test_pid)
  end

  defmodule ReconciliationAgentRunner do
    def run(issue, _recipient, _opts) do
      send(
        Application.fetch_env!(:symphony_elixir, :legacy_reconciliation_test_pid),
        {:issue_agent_started, issue.id, self()}
      )

      receive do
        :finish -> :ok
      end
    end

    def run_operator(_kind, _run_id, _recipient, _opts), do: :ok
  end

  setup do
    keys = [
      :agent_runner_module,
      :legacy_reconciliation_candidates,
      :legacy_reconciliation_test_pid,
      :linear_client_module
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    Application.put_env(:symphony_elixir, :agent_runner_module, ReconciliationAgentRunner)
    Application.put_env(:symphony_elixir, :linear_client_module, ReconciliationLinearClient)
    Application.put_env(:symphony_elixir, :legacy_reconciliation_test_pid, self())
    Application.put_env(:symphony_elixir, :legacy_reconciliation_candidates, [])
    FakePersistence.reset!()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_app_env(key, value) end)
    end)

    :ok
  end

  test "external durable reconciliation is polled without restoring listening, then dispatches after enable" do
    {:ok, loaded} = Workflow.load()
    {:ok, project} = FakePersistence.default_project()
    {:ok, _scopes} = FakePersistence.put_package_unchecked(project, loaded.config, loaded.prompt)

    different = put_in(loaded.config, ["polling", "interval_ms"], 9_999)

    {:ok, %{setting: {:conflict, conflict}}} =
      LegacyWorkflowConvergence.plan(
        [
          legacy_row("workflow-fake", project.id, project.slug, loaded.config, loaded.prompt),
          legacy_row("workflow-other", "project-other", "other", different, loaded.prompt)
        ],
        false
      )

    FakePersistence.put_legacy_instance_workflow_conflict!(conflict)
    assert :ok = WorkflowStore.force_reload()
    assert WorkflowStore.list_enabled() == []

    orchestrator_name = Module.concat(__MODULE__, :ReconciliationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    assert %{polling: %{listening?: false}} = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert {:ok, {:converged, _instance}} =
             FakePersistence.reconcile_legacy_instance_workflow_durable(project.slug)

    eventually(fn -> match?({:ok, _workflow}, WorkflowStore.for_project(project.id)) end)
    assert %{polling: %{listening?: false}} = Orchestrator.snapshot(orchestrator_name, 1_000)

    issue = %Issue{
      id: "legacy-reconciled-issue",
      identifier: "SYM-LEGACY",
      title: "Legacy reconciliation dispatch",
      state: "Ready",
      labels: [],
      blocked_by: []
    }

    Application.put_env(:symphony_elixir, :legacy_reconciliation_candidates, [issue])
    assert %{listening?: true} = Orchestrator.start_listening(orchestrator_name)
    send(pid, :run_poll_cycle)

    assert_receive :candidate_fetch, 2_000
    assert_receive {:issue_agent_started, "legacy-reconciled-issue", runner_pid}, 2_000
    send(runner_pid, :finish)
  end

  defp legacy_row(workflow_id, project_id, slug, config, prompt) do
    %{
      workflow_id: workflow_id,
      project_id: project_id,
      project_slug: slug,
      yaml_config: config,
      prompt_body: prompt,
      after_create_hook: nil,
      before_run_hook: nil,
      after_run_hook: nil,
      before_remove_hook: nil
    }
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

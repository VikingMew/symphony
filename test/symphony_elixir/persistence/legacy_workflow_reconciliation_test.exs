defmodule SymphonyElixir.Persistence.LegacyWorkflowReconciliationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.LegacyWorkflowConvergence
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.{Workflow, WorkflowStore}

  setup do
    FakePersistence.reset!()
    {:ok, loaded} = Workflow.load()
    %{loaded: loaded}
  end

  test "status reports zero without a singleton or conflict" do
    assert FakePersistence.legacy_instance_workflow_status() == {:ok, :zero}
    assert FakePersistence.reconcile_legacy_instance_workflow_durable("missing") == {:error, :zero}
  end

  test "invalid exact-slug selection preserves the whole conflict", %{loaded: loaded} do
    conflict = put_conflict!(loaded)

    assert FakePersistence.reconcile_legacy_instance_workflow_durable("ALPHA") ==
             {:error, {:invalid_selection, "ALPHA"}}

    assert FakePersistence.legacy_instance_workflow_status() == {:ok, {:conflict, conflict}}
  end

  test "transaction failure preserves both settings and valid selection remains retryable", %{
    loaded: loaded
  } do
    conflict = put_conflict!(loaded)
    FakePersistence.fail_next_legacy_reconciliation!(:write_failed)

    assert FakePersistence.reconcile_legacy_instance_workflow_durable("shared-b") ==
             {:error, {:transaction_failed, :write_failed}}

    assert FakePersistence.legacy_instance_workflow_status() == {:ok, {:conflict, conflict}}

    assert {:ok, {:converged, selected}} =
             FakePersistence.reconcile_legacy_instance_workflow_durable("shared-b")

    assert selected.prompt_body == loaded.prompt
    assert FakePersistence.legacy_instance_workflow_status() == {:ok, {:converged, selected}}

    assert {:ok, {:already_converged, ^selected}} =
             FakePersistence.reconcile_legacy_instance_workflow_durable("different")
  end

  test "selection can name either project sharing one canonical candidate", %{loaded: loaded} do
    put_conflict!(loaded)

    assert {:ok, {:converged, selected}} =
             FakePersistence.reconcile_legacy_instance_workflow_durable("shared-a")

    assert selected.prompt_body == loaded.prompt
  end

  test "publication failure retains durable convergence and retry is already-converged", %{
    loaded: loaded
  } do
    put_conflict!(loaded)
    pid = Process.whereis(WorkflowStore)
    true = Process.unregister(WorkflowStore)

    try do
      assert {:error, {:runtime_publication_failed, {:converged, selected}, {:refresh_failed, :cache_unavailable}}} =
               FakePersistence.reconcile_legacy_instance_workflow("shared-b")

      assert FakePersistence.instance_workflow() == selected
      assert FakePersistence.legacy_instance_workflow_status() == {:ok, {:converged, selected}}
    after
      true = Process.register(pid, WorkflowStore)
    end

    assert {:ok, {:already_converged, _selected}} =
             FakePersistence.reconcile_legacy_instance_workflow("shared-b")
  end

  defp put_conflict!(loaded) do
    different = put_in(loaded.config, ["polling", "interval_ms"], 9_999)

    {:ok, %{setting: {:conflict, conflict}}} =
      LegacyWorkflowConvergence.plan(
        [
          legacy_row("a", "shared-a", loaded.config, loaded.prompt),
          legacy_row("b", "shared-b", loaded.config, loaded.prompt),
          legacy_row("c", "different", different, "Different prompt")
        ],
        false
      )

    FakePersistence.put_legacy_instance_workflow_conflict!(conflict)
    conflict
  end

  defp legacy_row(id, slug, config, prompt) do
    %{
      workflow_id: "workflow-#{id}",
      project_id: "project-#{id}",
      project_slug: slug,
      yaml_config: config,
      prompt_body: prompt,
      after_create_hook: nil,
      before_run_hook: nil,
      after_run_hook: nil,
      before_remove_hook: nil
    }
  end
end

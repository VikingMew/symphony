defmodule SymphonyElixir.Config.LegacyWorkflowConvergenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.{LegacyWorkflowConvergence, WorkflowScopes}
  alias SymphonyElixir.Persistence.Project
  alias SymphonyElixir.Workflow

  setup do
    {:ok, loaded} = Workflow.load_example_package()
    %{config: loaded.config, prompt: loaded.prompt}
  end

  test "zero candidates leaves both settings absent" do
    assert {:ok, %{candidates: [], setting: :none}} = LegacyWorkflowConvergence.plan([], false)
  end

  test "one candidate writes the canonical instance and rewrites the project slice", context do
    row = legacy_row("b", "project-b", context.config, context.prompt)

    assert {:ok, %{candidates: [candidate], setting: {:instance, instance_value}}} =
             LegacyWorkflowConvergence.plan([row], false)

    assert instance_value == WorkflowScopes.dump_instance(candidate.instance)
    assert candidate.project_config == Map.take(context.config, WorkflowScopes.project_sections())
    assert Enum.sort(Map.keys(candidate.project_config)) == ["project", "tracker"]
    assert candidate.raw_workflow_md == Workflow.to_markdown(candidate.project_config, "")
    assert candidate.raw_workflow_md =~ "profiles:" == false
    assert candidate.raw_workflow_md =~ "workflow:" == false
    assert candidate.raw_workflow_md =~ context.prompt == false
  end

  test "duplicate-equal candidates converge and retain every contributor", context do
    rows = [
      legacy_row("b", "project-b", context.config, context.prompt),
      legacy_row("a", "project-a", context.config, context.prompt)
    ]

    assert {:ok, %{candidates: candidates, setting: {:instance, _value}}} =
             LegacyWorkflowConvergence.plan(rows, false)

    assert Enum.map(candidates, & &1.project_slug) == ["project-a", "project-b"]
  end

  test "multiple distinct candidates store exact paths and every project candidate", context do
    different = put_in(context.config, ["polling", "interval_ms"], 9_999)

    rows = [
      legacy_row("b", "shared-b", context.config, context.prompt),
      legacy_row("a", "shared-a", context.config, context.prompt),
      legacy_row("c", "different", different, "Different prompt")
    ]

    assert {:ok, %{setting: {:conflict, conflict}}} =
             LegacyWorkflowConvergence.plan(rows, false)

    assert Enum.map(conflict["candidates"], & &1["project_slug"]) == [
             "different",
             "shared-a",
             "shared-b"
           ]

    assert Enum.map(conflict["differing_paths"], & &1["path"]) == [
             "polling.interval_ms",
             "prompt_body"
           ]

    Enum.each(conflict["differing_paths"], fn difference ->
      assert Enum.map(difference["contributors"], & &1["project_slug"]) == [
               "different",
               "shared-a",
               "shared-b"
             ]
    end)

    assert {:ok, selected} = LegacyWorkflowConvergence.select_candidate(conflict, "shared-b")
    assert selected.prompt_body == context.prompt

    assert {:error, {:invalid_selection, "Shared-B"}} =
             LegacyWorkflowConvergence.select_candidate(conflict, "Shared-B")
  end

  test "non-blank legacy hooks overlay YAML before candidate equality", context do
    yaml_hook = put_in(context.config, [Access.key("hooks", %{}), "before_run"], "echo yaml")
    matching = legacy_row("a", "matching", yaml_hook, context.prompt, before_run_hook: "echo yaml")
    overriding = legacy_row("b", "overriding", yaml_hook, context.prompt, before_run_hook: " echo project ")
    blank = legacy_row("c", "blank", yaml_hook, context.prompt, before_run_hook: "  ")

    assert {:ok, %{setting: {:conflict, conflict}}} =
             LegacyWorkflowConvergence.plan([matching, overriding, blank], false)

    assert Enum.map(conflict["differing_paths"], & &1["path"]) == ["hooks.before_run"]

    assert {:ok, selected} = LegacyWorkflowConvergence.select_candidate(conflict, "overriding")
    assert selected.config["hooks"]["before_run"] == " echo project "

    assert {:ok, blank_selected} = LegacyWorkflowConvergence.select_candidate(conflict, "blank")
    assert blank_selected.config["hooks"]["before_run"] == "echo yaml"
  end

  test "all four legacy project hook columns map to their instance hook fields", context do
    row =
      legacy_row("a", "hooks", context.config, context.prompt,
        after_create_hook: "after create",
        before_run_hook: "before run",
        after_run_hook: "after run",
        before_remove_hook: "before remove"
      )

    assert {:ok, %{candidates: [candidate]}} = LegacyWorkflowConvergence.plan([row], false)

    assert candidate.instance.config["hooks"] == %{
             "after_create" => "after create",
             "before_run" => "before run",
             "after_run" => "after run",
             "before_remove" => "before remove"
           }
  end

  test "current project schema contains none of the migrated hook columns" do
    hook_fields = [:after_create_hook, :before_run_hook, :after_run_hook, :before_remove_hook]
    assert Enum.filter(Project.__schema__(:fields), &(&1 in hook_fields)) == []
  end

  test "an existing singleton is preserved while every workflow is still rewritten", context do
    row = legacy_row("a", "project-a", context.config, context.prompt)

    assert {:ok, %{candidates: [candidate], setting: :none}} =
             LegacyWorkflowConvergence.plan([row], true)

    assert candidate.project_config == Map.take(context.config, WorkflowScopes.project_sections())
    assert candidate.raw_workflow_md == Workflow.to_markdown(candidate.project_config, "")
  end

  test "candidate failure returns no partial migration plan", context do
    invalid = Map.put(context.config, "unknown", true)

    assert {:error, {:legacy_workflow, "workflow-b", {:out_of_scope_workflow_fields, :instance, ["unknown"]}}} =
             LegacyWorkflowConvergence.plan(
               [
                 legacy_row("a", "project-a", context.config, context.prompt),
                 legacy_row("b", "project-b", invalid, context.prompt)
               ],
               false
             )
  end

  test "status reports zero, conflict, and canonical convergence", context do
    assert {:ok, :zero} = LegacyWorkflowConvergence.status(nil, nil)

    {:ok, %{setting: {:conflict, conflict}}} =
      LegacyWorkflowConvergence.plan(
        [
          legacy_row("a", "project-a", context.config, context.prompt),
          legacy_row(
            "b",
            "project-b",
            put_in(context.config, ["polling", "interval_ms"], 9_999),
            context.prompt
          )
        ],
        false
      )

    assert {:ok, {:conflict, ^conflict}} = LegacyWorkflowConvergence.status(nil, conflict)

    {:ok, %{setting: {:instance, instance}}} =
      LegacyWorkflowConvergence.plan(
        [legacy_row("a", "project-a", context.config, context.prompt)],
        false
      )

    assert {:ok, {:converged, loaded}} = LegacyWorkflowConvergence.status(instance, conflict)
    assert WorkflowScopes.dump_instance(loaded) == instance
  end

  defp legacy_row(id, slug, config, prompt, attrs \\ []) do
    Map.merge(
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
      },
      Map.new(attrs)
    )
  end
end

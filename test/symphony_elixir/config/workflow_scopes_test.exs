defmodule SymphonyElixir.Config.WorkflowScopesTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias SymphonyElixir.Config.{Schema, WorkflowScopes}
  alias SymphonyElixir.Persistence.AppSetting
  alias SymphonyElixir.{Workflow, WorkflowForm, WorkflowSettingsPackage}

  test "instance workflow uses the typed app settings record" do
    value = %{"config" => %{"polling" => %{"interval_ms" => 1_000}}, "prompt_body" => "Prompt"}

    changeset = AppSetting.changeset(%AppSetting{}, %{key: "instance_workflow", value: value})

    assert changeset.valid?
    assert Changeset.apply_changes(changeset) == %AppSetting{key: "instance_workflow", value: value}
    assert AppSetting.changeset(%AppSetting{}, %{value: value}).valid? == false
  end

  test "portable workflow splits into instance and project durable slices" do
    {:ok, loaded} = Workflow.load()

    assert {:ok, instance, project} = WorkflowScopes.split_package(loaded.config, loaded.prompt)
    assert instance.config == Map.take(loaded.config, WorkflowScopes.instance_sections())
    assert project == Map.take(loaded.config, WorkflowScopes.project_sections())
    assert instance.prompt_body == loaded.prompt
    assert Map.has_key?(instance.config, "workflow") == false
    assert Map.has_key?(project, "workflow") == false

    assert {:ok, combined} = WorkflowScopes.combined(instance, project)
    assert combined.prompt == loaded.prompt
    assert combined.config["workflow"] == Schema.default_workflow_policy()
  end

  test "slice parsing canonicalizes atom keys without dropping owned fields" do
    assert {:ok, instance, project} =
             WorkflowScopes.split_package(
               %{
                 polling: %{interval_ms: 1_234},
                 tracker: %{kind: "linear"}
               },
               "Prompt"
             )

    assert instance == %{config: %{"polling" => %{"interval_ms" => 1_234}}, prompt_body: "Prompt"}
    assert project == %{"tracker" => %{"kind" => "linear"}}
  end

  test "slice parsing rejects duplicate canonical keys" do
    assert {:error, {:duplicate_workflow_fields, :instance, ["polling"]}} =
             WorkflowScopes.split_package(
               %{"polling" => %{"interval_ms" => 1_000}, polling: %{interval_ms: 2_000}},
               ""
             )
  end

  test "portable routing input never becomes durable or editable policy" do
    {:ok, loaded} = Workflow.load()

    config =
      Map.put(loaded.config, "workflow", %{
        "states" => %{"Invented" => %{"profile" => "implementation"}}
      })

    assert {:ok, instance, project} = WorkflowScopes.split_package(config, loaded.prompt)
    assert Map.has_key?(instance.config, "workflow") == false
    assert Map.has_key?(project, "workflow") == false
    assert {:ok, combined} = WorkflowScopes.combined(instance, project)
    assert combined.config["workflow"] == Schema.default_workflow_policy()
  end

  test "project slice rejects instance, prompt, secret, hook, and workflow fields" do
    assert {:error, {:out_of_scope_workflow_fields, :project, ["codex"]}} =
             WorkflowScopes.validate_project_config(%{"codex" => %{}})

    assert {:error, {:out_of_scope_workflow_fields, :project, ["tracker.api_key"]}} =
             WorkflowScopes.validate_project_config(%{"tracker" => %{"api_key" => "secret"}})

    assert {:error, {:out_of_scope_workflow_fields, :project, ["tracker.api_key"]}} =
             WorkflowScopes.validate_project_config(%{tracker: %{api_key: "secret"}})

    assert {:error, {:out_of_scope_workflow_fields, :project, ["prompt_body"]}} =
             WorkflowScopes.project_from_loaded(%{config: %{}, prompt: "base prompt"})

    assert {:error, {:out_of_scope_workflow_fields, :project, ["workflow"]}} =
             WorkflowScopes.validate_project_config(%{"workflow" => Schema.default_workflow_policy()})
  end

  test "instance value rejects project fields and unknown nested fields" do
    assert {:error, {:out_of_scope_workflow_fields, :instance, ["project"]}} =
             WorkflowScopes.new_instance(%{"project" => %{}}, "")

    assert {:error, {:out_of_scope_workflow_fields, :instance, ["codex.unknown"]}} =
             WorkflowScopes.new_instance(%{"codex" => %{"unknown" => true}}, "")

    assert {:error, {:out_of_scope_workflow_fields, :instance, ["source"]}} =
             WorkflowScopes.load_instance(%{
               "config" => %{},
               "prompt_body" => "",
               "source" => "legacy"
             })
  end

  test "form and package adapters expose separate durable scopes" do
    {:ok, loaded} = Workflow.load()
    draft = WorkflowForm.from_loaded(loaded)

    assert {:ok, instance, project} = WorkflowForm.to_scopes(draft)
    assert {:ok, ^instance, ^project} = WorkflowSettingsPackage.durable_scopes(draft)
    assert {:ok, combined_draft} = WorkflowSettingsPackage.combined_draft(instance, project)
    assert {:ok, round_tripped_instance, round_tripped_project} = WorkflowForm.to_scopes(combined_draft)
    assert round_tripped_instance == instance
    assert round_tripped_project == project

    assert {:error, {:out_of_scope_workflow_fields, :project, ["prompt_body"]}} =
             WorkflowForm.to_project_scope(draft)
  end
end

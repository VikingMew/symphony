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
    {:ok, loaded} = Workflow.load_example_package()

    assert {:ok, instance, project} = WorkflowScopes.split_package(loaded.config, loaded.prompt)
    assert instance.config == Map.take(loaded.config, WorkflowScopes.instance_sections())

    assert project == %{
             "tracker" => %{
               "active_states" => ["Todo", "Ready", "In Progress"],
               "kind" => "linear",
               "terminal_states" => ["Canceled", "Cancelled", "Duplicate", "Done"]
             },
             "project" => %{
               "cleanup_commands" => ["mise exec -- mix workspace.before_remove"],
               "required_gates" => loaded.config["project"]["required_gates"],
               "setup_commands" => loaded.config["project"]["setup_commands"]
             }
           }

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

  test "dispatch scope round-trips through the instance form and package boundary" do
    {:ok, loaded} = Workflow.load_example_package()

    config =
      Map.put(loaded.config, "dispatch_scope", %{
        "linear_team_key" => "KRN",
        "linear_project_slug" => "koroni",
        "fallback_project_slug" => "default"
      })

    draft = WorkflowForm.from_loaded(%{loaded | config: config})
    assert draft["dispatch_linear_team_key"] == "KRN"
    assert draft["dispatch_linear_project_slug"] == "koroni"
    assert draft["dispatch_fallback_project_slug"] == "default"

    assert {:ok, instance, _project} = WorkflowForm.to_scopes(draft)

    assert instance.config["dispatch_scope"] == %{
             "fallback_project_slug" => "default",
             "linear_project_slug" => "koroni",
             "linear_team_key" => "KRN"
           }
  end

  test "dispatch scope clears inherited optional values and rejects a project without a team" do
    {:ok, loaded} = Workflow.load_example_package()

    config =
      Map.put(loaded.config, "dispatch_scope", %{
        "linear_team_key" => "KRN",
        "linear_project_slug" => "koroni",
        "fallback_project_slug" => "default"
      })

    draft =
      WorkflowForm.from_loaded(%{loaded | config: config})
      |> Map.put("dispatch_linear_team_key", "")
      |> Map.put("dispatch_linear_project_slug", "")
      |> Map.put("dispatch_fallback_project_slug", "")

    assert {:ok, instance, _project} = WorkflowForm.to_scopes(draft)
    assert get_in(instance.config, ["dispatch_scope", "linear_team_key"]) == nil
    assert get_in(instance.config, ["dispatch_scope", "linear_project_slug"]) == nil
    assert get_in(instance.config, ["dispatch_scope", "fallback_project_slug"]) == nil

    assert {:error, :linear_project_requires_team} =
             WorkflowScopes.new_instance(
               %{"dispatch_scope" => %{"linear_project_slug" => "koroni"}},
               "Prompt"
             )
  end

  test "slice parsing rejects duplicate canonical keys" do
    assert {:error, {:duplicate_workflow_fields, :instance, ["polling"]}} =
             WorkflowScopes.split_package(
               %{"polling" => %{"interval_ms" => 1_000}, polling: %{interval_ms: 2_000}},
               ""
             )
  end

  test "portable routing input never becomes durable or editable policy" do
    {:ok, loaded} = Workflow.load_example_package()

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
    {:ok, loaded} = Workflow.load_example_package()
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

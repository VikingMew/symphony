defmodule SymphonyElixir.WorkflowSettingsPackageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TestSupport.WorkflowFixtures
  alias SymphonyElixir.{WorkflowForm, WorkflowSettingsPackage}

  test "imports workflow yaml without replacing profiles or prompt" do
    current =
      WorkflowForm.empty()
      |> Map.put("prompt_body", "Keep current prompt")
      |> Map.put("profiles", %{
        "implementation" => %{
          "name" => "Implementation",
          "executor_type" => "codex_agent",
          "prompt_mode" => "extend",
          "prompt_template" => "Keep current profile",
          "allow_description" => "false",
          "allow_comment" => "true",
          "allow_result" => "true",
          "target_states" => "Done"
        }
      })

    assert {:ok, "workflow.yml", draft} =
             WorkflowSettingsPackage.import_draft(WorkflowFixtures.settings_workflow_yaml(), current)

    assert draft["prompt_body"] == "Keep current prompt"
    assert draft["profiles"]["implementation"]["prompt_template"] == "Keep current profile"
    assert draft["active_states"] =~ "Ready"
  end

  test "imports profiles yaml without replacing workflow routing" do
    current = WorkflowForm.empty() |> Map.put("active_states", "Ready\nIn Progress")

    assert {:ok, "profiles.yml", draft} =
             WorkflowSettingsPackage.import_draft(WorkflowFixtures.settings_profiles_yaml(), current)

    assert draft["prompt_body"] =~ "Imported base prompt"
    assert draft["profiles"]["implementation"]["prompt_template"] =~ "Imported implementation prompt"
    assert draft["active_states"] == "Ready\nIn Progress"
  end

  test "canonical diff ignores equivalent workflow raw formatting" do
    raw = workflow_raw!(WorkflowForm.empty())
    changed_raw = workflow_raw!(WorkflowForm.empty() |> Map.put("prompt_body", "Run a workflow from the Web UI."))

    assert WorkflowSettingsPackage.changed?(raw, raw) == false
    assert WorkflowSettingsPackage.changed?(raw, raw <> "\n") == false
    assert WorkflowSettingsPackage.changed?(raw, changed_raw) == true
  end

  test "settings serialization replaces workflow policy edits with the code contract" do
    draft =
      WorkflowForm.empty()
      |> Map.put("workflow_states", %{"Legacy" => %{"profile" => "implementation"}})
      |> Map.put("human_review_states", "Legacy Review")
      |> Map.put("allowed_transitions", [
        %{"from" => "Legacy", "to" => "Legacy Review", "actor" => "human"}
      ])

    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert config["workflow"] == Schema.default_workflow_policy()
  end

  test "profiles package round trip preserves the default operator profiles" do
    profiles_yaml = File.read!("profiles.yml")

    assert {:ok, "profiles.yml", imported_draft} =
             WorkflowSettingsPackage.import_draft(profiles_yaml, WorkflowForm.empty())

    exported_raw = workflow_raw!(imported_draft)
    assert {:ok, round_tripped_draft} = WorkflowForm.from_raw(exported_raw)
    assert {:ok, round_tripped_config} = WorkflowForm.to_config(round_tripped_draft)

    defaults = Schema.default_profiles()

    assert Map.take(round_tripped_config["profiles"], ["nap", "day_dreaming"]) ==
             Map.take(defaults, ["nap", "day_dreaming"])
  end

  defp workflow_raw!(draft) do
    case WorkflowForm.to_raw(draft) do
      {:ok, raw} -> raw
      {:error, reason} -> flunk("expected raw workflow, got #{inspect(reason)}")
    end
  end
end

defmodule SymphonyElixir.WorkflowSettingsPackageTest do
  use SymphonyElixir.TestSupport

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

  test "restores only the selected settings section" do
    current = %{"prompt_body" => "current prompt", "profiles" => %{"current" => %{}}, "active_states" => "Ready"}
    history = %{"prompt_body" => "history prompt", "profiles" => %{"history" => %{}}, "active_states" => "Done"}

    assert WorkflowSettingsPackage.restore_section(:agents, current, history) == %{
             "prompt_body" => "history prompt",
             "profiles" => %{"history" => %{}},
             "active_states" => "Ready"
           }

    assert WorkflowSettingsPackage.restore_section(:workflow, current, history) == %{
             "prompt_body" => "current prompt",
             "profiles" => %{"current" => %{}},
             "active_states" => "Done"
           }
  end

  test "canonical diff ignores equivalent workflow raw formatting" do
    raw = workflow_raw!(WorkflowForm.empty())
    changed_raw = workflow_raw!(WorkflowForm.empty() |> Map.put("prompt_body", "Run a workflow from the Web UI."))

    assert WorkflowSettingsPackage.changed?(raw, raw) == false
    assert WorkflowSettingsPackage.changed?(raw, raw <> "\n") == false
    assert WorkflowSettingsPackage.changed?(raw, changed_raw) == true
  end

  defp workflow_raw!(draft) do
    case WorkflowForm.to_raw(draft) do
      {:ok, raw} -> raw
      {:error, reason} -> flunk("expected raw workflow, got #{inspect(reason)}")
    end
  end
end

defmodule SymphonyElixir.WorkflowSettingsPackageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TestSupport.WorkflowFixtures
  alias SymphonyElixir.{Workflow, WorkflowForm, WorkflowSettingsPackage}

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
    assert draft["codex_thread_sandbox"] == "danger-full-access"
    assert draft["codex_turn_sandbox_preset"] == "danger_full_access"
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
    profiles_yaml = File.read!(Path.join(Workflow.example_package_root(), "profiles.yml"))

    assert {:ok, "profiles.yml", imported_draft} =
             WorkflowSettingsPackage.import_draft(profiles_yaml, WorkflowForm.empty())

    exported_raw = workflow_raw!(imported_draft)
    assert {:ok, round_tripped_draft} = WorkflowForm.from_raw(exported_raw)
    assert {:ok, round_tripped_config} = WorkflowForm.to_config(round_tripped_draft)

    defaults = Schema.default_profiles()

    assert Map.take(round_tripped_config["profiles"], ["nap", "day_dreaming"]) ==
             Map.take(defaults, ["nap", "day_dreaming"])
  end

  test "default profiles and package carry the owning-design contract" do
    profiles_yaml = File.read!(Path.join(Workflow.example_package_root(), "profiles.yml"))
    defaults = Schema.default_profiles()

    for source <- [profiles_yaml, defaults["refinement"]["prompt"]["template"]] do
      assert source =~ "Owning design docs"
      assert source =~ "Change classification: behavior/architecture|non-behavior"
      assert source =~ "Owner registration plan:"
    end

    for source <- [profiles_yaml, defaults["implementation"]["prompt"]["template"]] do
      assert source =~ "actual diff"
      assert source =~ "runtime configuration semantics"
      assert source =~ "documentation-alignment row"
      assert source =~ "disclosed in the PR body"
    end
  end

  test "workflow package round trip preserves analytics thresholds" do
    workflow_yaml = File.read!(Path.join(Workflow.example_package_root(), "workflow.yml"))

    assert workflow_yaml =~ "Implementation completion uses the `handoff`"

    assert {:ok, "workflow.yml", draft} =
             WorkflowSettingsPackage.import_draft(workflow_yaml, WorkflowForm.empty())

    assert {:ok, config} = WorkflowForm.to_config(draft)

    assert config["analytics"] == %{
             "refinement_rounds_average_max" => 2.0,
             "first_handoff_observed_return_rate_max" => 0.5,
             "blocked_rate_max" => 0.25,
             "latest_description_length_min" => 200,
             "rework_rate_max" => 0.5,
             "per_issue_total_tokens_max" => 1_000_000
           }

    assert get_in(config, ["codex", "thread_sandbox"]) == "danger-full-access"
    assert get_in(config, ["codex", "turn_sandbox_policy"]) == %{"type" => "dangerFullAccess"}

    assert get_in(config, ["workflow", "tool_policy", "linear", "exposed_tools"]) ==
             ["linear_task_read", "linear_task_update"]

    assert get_in(config, ["workflow", "tool_policy", "github", "exposed_tools"]) ==
             ["create_pull_request"]
  end

  test "workflow import promotes legacy Codex command selectors and exposes the conversion diff" do
    yaml =
      WorkflowFixtures.workflow_package_yaml(%{
        "codex" => %{
          "command" => "codex --config 'model=\"gpt-5.5\"' -c model_reasoning_effort=xhigh app-server"
        }
      })

    assert {:ok, stage} =
             WorkflowSettingsPackage.stage_import(yaml, WorkflowForm.empty(), source: :paste)

    assert stage.draft["codex_command"] == "codex app-server"
    assert stage.draft["codex_model"] == "gpt-5.5"
    assert stage.draft["codex_reasoning_effort"] == "xhigh"
    assert "Runtime" in stage.affected_areas

    assert Enum.any?(stage.diff, &match?(%{path: "codex.command", after: "codex app-server"}, &1))
    assert Enum.any?(stage.diff, &match?(%{path: "codex.model", after: "gpt-5.5"}, &1))

    assert Enum.any?(
             stage.diff,
             &match?(%{path: "codex.reasoning_effort", after: "xhigh"}, &1)
           )

    assert {:ok, config} = WorkflowForm.to_config(stage.draft)
    assert get_in(config, ["codex", "command"]) == "codex app-server"
    assert get_in(config, ["codex", "model"]) == "gpt-5.5"
    assert get_in(config, ["codex", "reasoning_effort"]) == "xhigh"
  end

  test "workflow import preserves explicit Codex selectors over legacy command values" do
    yaml =
      WorkflowFixtures.workflow_package_yaml(%{
        "codex" => %{
          "command" => "codex -c model=gpt-5.5 -c model_reasoning_effort=xhigh app-server",
          "model" => "gpt-5.6-sol",
          "reasoning_effort" => "high"
        }
      })

    assert {:ok, "workflow.yml", draft} =
             WorkflowSettingsPackage.import_draft(yaml, WorkflowForm.empty())

    assert draft["codex_command"] == "codex app-server"
    assert draft["codex_model"] == "gpt-5.6-sol"
    assert draft["codex_reasoning_effort"] == "high"
  end

  defp workflow_raw!(draft) do
    case WorkflowForm.to_raw(draft) do
      {:ok, raw} -> raw
      # docs/negative-assertion-audit.md control-flow contract: fail explicitly if this branch is reached.
      {:error, reason} -> flunk("expected raw workflow, got #{inspect(reason)}")
    end
  end
end

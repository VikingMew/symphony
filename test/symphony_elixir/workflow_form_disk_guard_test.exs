defmodule SymphonyElixir.WorkflowFormDiskGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Workflow, WorkflowForm}

  test "empty form and first save use schema defaults" do
    defaults = Schema.defaults()
    setup_config = Workflow.setup_required_workflow().config
    draft = WorkflowForm.empty()

    assert get_in(setup_config, ["workspace", "root"]) ==
             get_in(defaults, ["workspace", "root"])

    assert get_in(setup_config, ["agent", "max_concurrent_agents"]) == 10
    assert draft["workspace_root"] == get_in(defaults, ["workspace", "root"])

    assert draft["agent_max_concurrent_agents"] ==
             defaults |> get_in(["agent", "max_concurrent_agents"]) |> Integer.to_string()

    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert get_in(config, ["workspace", "root"]) == get_in(defaults, ["workspace", "root"])
    assert get_in(config, ["agent", "max_concurrent_agents"]) == 10
  end

  test "displays existing byte threshold as GiB" do
    draft =
      WorkflowForm.from_loaded(%{
        prompt: "Prompt",
        config: %{"workspace" => %{"min_free_bytes" => 1_073_741_824}}
      })

    assert draft["workspace_min_free_gib"] == "1"
    refute Map.has_key?(draft, "workspace_min_free_bytes")
  end

  test "converts GiB values to byte config" do
    draft =
      WorkflowForm.empty()
      |> Map.put("workspace_min_free_gib", "2")

    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert get_in(config, ["workspace", "min_free_bytes"]) == 2_147_483_648

    draft = Map.put(draft, "workspace_min_free_gib", "0.5")
    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert get_in(config, ["workspace", "min_free_bytes"]) == 536_870_912

    draft = Map.put(draft, "workspace_min_free_gib", "0")
    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert get_in(config, ["workspace", "min_free_bytes"]) == 0
  end

  test "validates GiB values with operator-facing label" do
    draft =
      WorkflowForm.empty()
      |> Map.put("workspace_min_free_gib", "not-a-number")

    assert {:error, "Minimum free GiB must be zero or a positive number"} = WorkflowForm.to_config(draft)

    assert WorkflowForm.field_errors(draft) == %{
             "workspace_min_free_gib" => "Minimum free GiB must be zero or a positive number"
           }
  end
end

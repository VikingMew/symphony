defmodule SymphonyElixir.WorkflowFormDiskGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkflowForm

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

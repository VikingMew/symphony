defmodule SymphonyElixir.WorkflowFormCodexModelTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkflowForm

  test "round-trips codex model and reasoning effort through workflow raw content" do
    draft =
      WorkflowForm.empty()
      |> Map.put("codex_model", "gpt-6-astra")
      |> Map.put("codex_reasoning_effort", "ultra")

    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert get_in(config, ["codex", "model"]) == "gpt-6-astra"
    assert get_in(config, ["codex", "reasoning_effort"]) == "ultra"

    assert {:ok, raw} = WorkflowForm.to_raw(draft)
    assert raw =~ ~s(model: "gpt-6-astra")
    assert raw =~ ~s(reasoning_effort: "ultra")

    assert {:ok, round_tripped} = WorkflowForm.from_raw(raw)
    assert round_tripped["codex_model"] == "gpt-6-astra"
    assert round_tripped["codex_reasoning_effort"] == "ultra"
  end

  test "blank selectors clear model and reasoning effort instead of preserving base values" do
    draft =
      WorkflowForm.from_loaded(%{
        config: %{
          "codex" => %{
            "command" => "codex app-server",
            "model" => "gpt-5.5",
            "reasoning_effort" => "xhigh"
          }
        },
        prompt: "Prompt"
      })
      |> Map.put("codex_model", "")
      |> Map.put("codex_reasoning_effort", " ")

    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert Map.has_key?(config["codex"], "model") == false
    assert Map.has_key?(config["codex"], "reasoning_effort") == false
  end

  test "codex selector field errors reject unknown values and unsupported combinations" do
    invalid_model =
      WorkflowForm.empty()
      |> Map.put("codex_model", "gpt-future")

    assert WorkflowForm.field_errors(invalid_model)["codex_model"] =~ "Codex model must be one of:"
    assert {:error, message} = WorkflowForm.to_config(invalid_model)
    assert message =~ "Codex model must be one of:"

    invalid_effort =
      WorkflowForm.empty()
      |> Map.put("codex_reasoning_effort", "warp")

    assert WorkflowForm.field_errors(invalid_effort)["codex_reasoning_effort"] =~ "Codex reasoning effort must be one of:"
    assert {:error, message} = WorkflowForm.to_config(invalid_effort)
    assert message =~ "Codex reasoning effort must be one of:"

    unsupported =
      WorkflowForm.empty()
      |> Map.put("codex_model", "gpt-5.5")
      |> Map.put("codex_reasoning_effort", "ultra")

    assert WorkflowForm.field_errors(unsupported)["codex_reasoning_effort"] ==
             "Codex reasoning effort must be one of low, medium, high, xhigh for model gpt-5.5"

    assert {:error, message} = WorkflowForm.to_config(unsupported)
    assert message == "Codex reasoning effort must be one of low, medium, high, xhigh for model gpt-5.5"
  end
end

defmodule SymphonyElixir.WorkflowFormRateLimitGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkflowForm

  test "defaults rate-limit gate fields into the workflow draft" do
    draft = WorkflowForm.empty()

    assert draft["codex_rate_limit_gate_enabled"] == "true"
    assert draft["codex_rate_limit_gate_5h_threshold_percent"] == "5"
    assert draft["codex_rate_limit_gate_7d_threshold_percent"] == "3"
    assert draft["codex_rate_limit_gate_post_reset_delay_ms"] == "1200000"
  end

  test "saves custom rate-limit gate thresholds and delay" do
    draft =
      WorkflowForm.empty()
      |> Map.put("codex_rate_limit_gate_enabled", "true")
      |> Map.put("codex_rate_limit_gate_5h_threshold_percent", "8.5")
      |> Map.put("codex_rate_limit_gate_7d_threshold_percent", "4")
      |> Map.put("codex_rate_limit_gate_post_reset_delay_ms", "600000")

    assert {:ok, config} = WorkflowForm.to_config(draft)
    assert get_in(config, ["codex", "rate_limit_gate_enabled"]) == true
    assert get_in(config, ["codex", "rate_limit_gate_5h_threshold_percent"]) == 8.5
    assert get_in(config, ["codex", "rate_limit_gate_7d_threshold_percent"]) == 4.0
    assert get_in(config, ["codex", "rate_limit_gate_post_reset_delay_ms"]) == 600_000
  end

  test "validates rate-limit gate percentages" do
    draft =
      WorkflowForm.empty()
      |> Map.put("codex_rate_limit_gate_5h_threshold_percent", "101")

    assert {:error, "5-hour rate-limit threshold must be between 0 and 100"} = WorkflowForm.to_config(draft)
    assert WorkflowForm.field_errors(draft)["codex_rate_limit_gate_5h_threshold_percent"] == "5-hour rate-limit threshold must be between 0 and 100"
  end
end

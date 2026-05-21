defmodule SymphonyElixir.Orchestrator.InputBlockerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.InputBlocker

  test "classifies Codex input and approval requirements as blocked" do
    payload = %{"method" => "turn/input_required", "params" => %{"reason" => "needs operator"}}

    assert {:blocked, :turn_input_required, ^payload} = InputBlocker.blocked_reason({:turn_input_required, payload})
    assert InputBlocker.blocked?({:approval_required, %{}})
    assert InputBlocker.summary({:turn_input_required, payload}) =~ "waiting for operator input"
    assert InputBlocker.event({:approval_required, %{}}) == :approval_required
    assert InputBlocker.label({:approval_required, %{}}) == "Approval required"
  end

  test "leaves normal agent failures retryable" do
    refute InputBlocker.blocked?({:workspace_hook_timeout, "project_bootstrap", 1_000, %{}})
    assert InputBlocker.blocked_reason({:codex_startup_failed, %{}}) == :retryable
  end
end

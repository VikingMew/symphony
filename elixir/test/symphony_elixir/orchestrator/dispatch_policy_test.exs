defmodule SymphonyElixir.Orchestrator.DispatchPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.DispatchPolicy

  test "candidate dispatch honors active states, terminal states, executors, and state limits" do
    state = %Orchestrator.State{
      max_concurrent_agents: 2,
      running: %{
        "running-ready" => %{issue: issue("running-ready", "Ready")}
      },
      claimed: MapSet.new()
    }

    settings = dispatch_settings(max_for_state: fn "Ready" -> 1 end)

    refute DispatchPolicy.should_dispatch_issue?(issue("next-ready", "Ready"), state, settings)

    open_state = %{state | running: %{}}
    assert DispatchPolicy.should_dispatch_issue?(issue("next-ready", "Ready"), open_state, settings)

    refute DispatchPolicy.should_dispatch_issue?(
             issue("review", "Needs Review"),
             open_state,
             dispatch_settings(human_review?: fn "Needs Review" -> true end)
           )

    refute DispatchPolicy.should_dispatch_issue?(
             issue("manual", "Ready"),
             open_state,
             dispatch_settings(executor: fn "Ready" -> "human" end)
           )
  end

  test "worker selection keeps configured order when load ties" do
    state = %Orchestrator.State{running: %{}}

    assert DispatchPolicy.select_worker_host(state, nil, %{
             ssh_hosts: ["worker-a", "worker-b"],
             max_concurrent_agents_per_host: 2
           }) == "worker-a"
  end

  defp issue(id, state, attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: String.upcase(id),
          title: id,
          state: state,
          blocked_by: []
        ],
        attrs
      )
    )
  end

  defp dispatch_settings(opts) do
    %{
      active_states: DispatchPolicy.normalized_state_set(["Ready", "Needs Review"]),
      terminal_states: DispatchPolicy.normalized_state_set(["Done"]),
      max_concurrent_agents: 2,
      max_concurrent_agents_for_state: Keyword.get(opts, :max_for_state, fn _state -> 2 end),
      workflow_executor_for_state: Keyword.get(opts, :executor, fn _state -> "codex_agent" end),
      human_review_state?: Keyword.get(opts, :human_review?, fn _state -> false end)
    }
  end
end

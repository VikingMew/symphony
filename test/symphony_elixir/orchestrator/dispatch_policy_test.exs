defmodule SymphonyElixir.Orchestrator.DispatchPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.DispatchPolicy

  test "candidate dispatch honors deployment capacity, states, and executors" do
    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{
        "running-ready" => %Orchestrator.RunningIssue{issue: issue("running-ready", "Ready")}
      },
      claimed: MapSet.new()
    }

    settings = dispatch_settings([])

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

  test "refine-only listening dispatches only refinement states" do
    state = %Orchestrator.State{max_concurrent_agents: 2, running: %{}, claimed: MapSet.new()}

    settings =
      dispatch_settings(
        active_states: ["Refining", "Ready", "In Progress"],
        listening_mode: :listening_refine_only,
        refinement_states: ["Refining"]
      )

    assert DispatchPolicy.should_dispatch_issue?(issue("refining", "Refining"), state, settings)
    refute DispatchPolicy.should_dispatch_issue?(issue("ready", "Ready"), state, settings)
    refute DispatchPolicy.should_dispatch_issue?(issue("progress", "In Progress"), state, settings)
    refute DispatchPolicy.should_dispatch_issue?(issue("merge", "Ready to Merge"), state, settings)
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
      active_states: DispatchPolicy.normalized_state_set(Keyword.get(opts, :active_states, ["Ready", "Needs Review"])),
      terminal_states: DispatchPolicy.normalized_state_set(["Done"]),
      listening_mode: Keyword.get(opts, :listening_mode, :listening_all),
      refinement_states: DispatchPolicy.normalized_state_set(Keyword.get(opts, :refinement_states, ["Refining"])),
      max_concurrent_agents: 2,
      workflow_executor_for_state: Keyword.get(opts, :executor, fn _state -> "codex_agent" end),
      human_review_state?: Keyword.get(opts, :human_review?, fn _state -> false end)
    }
  end
end

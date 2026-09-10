defmodule SymphonyElixir.EnvironmentFailureCircuitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.EnvironmentFailureCircuit

  @reliability_contract "docs/spec-reliability-security.md §14.5"
  @observability_contract "docs/spec-observability.md §13.8"
  @bwrap "bwrap: No permissions to create a new namespace"

  setup do
    now = start_supervised!({Agent, fn -> ~U[2026-09-09 02:16:00Z] end})
    circuit = Module.concat(__MODULE__, "Circuit#{System.unique_integer([:positive])}")

    start_supervised!({EnvironmentFailureCircuit, name: circuit, now: fn -> Agent.get(now, & &1) end})

    %{circuit: circuit, now: now}
  end

  test "#{@reliability_contract} and #{@observability_contract}: same fingerprint across threshold issues opens once",
       %{circuit: circuit} do
    assert %{active: false, alert: false, distinct_issue_count: 1} =
             EnvironmentFailureCircuit.record_failure("SYM-1", @bwrap, %{issue_id: "issue-1"}, circuit)

    assert %{active: false, alert: false, distinct_issue_count: 2} =
             EnvironmentFailureCircuit.record_failure("SYM-2", @bwrap, %{issue_id: "issue-2"}, circuit)

    assert %{active: true, alert: true} =
             opened =
             EnvironmentFailureCircuit.record_failure("SYM-3", @bwrap, %{issue_id: "issue-3"}, circuit)

    assert opened.status == :tripped
    assert opened.triggering_fingerprint == EnvironmentFailureCircuit.fingerprint(@bwrap)
    assert opened.threshold == EnvironmentFailureCircuit.threshold()
    assert opened.window_ms == EnvironmentFailureCircuit.window_ms()
    assert opened.issue_identifiers == ["SYM-1", "SYM-2", "SYM-3"]
    assert {:block, blocked} = EnvironmentFailureCircuit.check(circuit)
    assert blocked == Map.delete(opened, :alert)

    assert %{active: true, alert: false, triggering_fingerprint: triggering_fingerprint} =
             EnvironmentFailureCircuit.record_failure("SYM-4", @bwrap, %{issue_id: "issue-4"}, circuit)

    assert triggering_fingerprint == opened.triggering_fingerprint
  end

  test "#{@reliability_contract}: below threshold, repeated issue, mixed fingerprints, and expired windows stay open=false",
       %{circuit: circuit, now: now} do
    assert %{active: false, distinct_issue_count: 1} =
             EnvironmentFailureCircuit.record_failure("SYM-1", @bwrap, %{}, circuit)

    assert %{active: false, distinct_issue_count: 1} =
             EnvironmentFailureCircuit.record_failure("SYM-1", @bwrap, %{}, circuit)

    assert %{active: false, distinct_issue_count: 1} =
             EnvironmentFailureCircuit.record_failure("SYM-2", "missing dependency: make", %{}, circuit)

    assert :allow = EnvironmentFailureCircuit.check(circuit)

    EnvironmentFailureCircuit.reset(circuit)
    EnvironmentFailureCircuit.record_failure("SYM-1", @bwrap, %{}, circuit)
    EnvironmentFailureCircuit.record_failure("SYM-2", @bwrap, %{}, circuit)
    Agent.update(now, &DateTime.add(&1, 31, :minute))

    assert %{active: false, distinct_issue_count: 1} =
             EnvironmentFailureCircuit.record_failure("SYM-3", @bwrap, %{}, circuit)
  end

  test "#{@reliability_contract}: success clears only a pre-trip consecutive streak and reset clears an open circuit",
       %{circuit: circuit} do
    EnvironmentFailureCircuit.record_failure("SYM-1", @bwrap, %{}, circuit)
    assert %{active: false, consecutive_failures: 0} = EnvironmentFailureCircuit.record_success("SYM-OK", circuit)

    EnvironmentFailureCircuit.record_failure("SYM-1", @bwrap, %{}, circuit)
    EnvironmentFailureCircuit.record_failure("SYM-2", @bwrap, %{}, circuit)
    assert %{active: true, alert: true} = EnvironmentFailureCircuit.record_failure("SYM-3", @bwrap, %{}, circuit)

    assert %{active: true} = EnvironmentFailureCircuit.record_success("SYM-OK", circuit)
    assert %{active: false, triggering_fingerprint: nil, consecutive_failures: 0} = EnvironmentFailureCircuit.reset(circuit)
    assert :allow = EnvironmentFailureCircuit.check(circuit)
  end
end

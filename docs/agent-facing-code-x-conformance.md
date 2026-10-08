---
title: Agent-Facing Code X Conformance Record
genre: reference
domain: [governance, code-quality, testing]
status: current
language: en
owner: SymphonyElixir.AgentCodeXCheck
updated: 2026-09-27
---

# Agent-Facing Code X Conformance Record

This L4 record stores current repository facts for X-01 through X-05. The
[Agent-facing code design](agent-facing-code-design.md#6-x-group-test-governance) owns the fields,
checker boundary, and ratchet lifecycle. Passing code conformance and passing test conformance are
independent claims: neither result supplies evidence for the other.

The record uses only the layer boundary required for this audit. Machine-checkable work belongs to
Layer 1 or 2; runtime behavior belongs to Layer 3 or 4. Every threshold clause names exactly one
layer. All X clauses in this repository are enforced by deterministic repository checks, so their
execution kind is `machine_check` and their current layer is Layer 1.

Calibration counts one manually labelled finding or expected checker outcome as one sample point.
The disagreement rate is `disagreement_count / sample_count`. The eight first-party checkers in
scope are the seven existing repository-content judges plus `mix agent_code_x.check`; command
sequencers and upstream tools are outside this inventory.

The tagged YAML block is the current-fact record consumed by `mix agent_code_x.check`.

<!-- agent-code-x-record:start -->
```yaml
schema: agent-facing-code-x-conformance
clauses:
  - id: X-01
    threshold: false
    baseline_status: partially_satisfied
    final_status: satisfied
    evidence: "docs/agent-facing-code-design.md#6-x-group-test-governance; AGENTS.md#tests-and-validation"
    execution_kind: machine_check
    test_layer: 1
    execution: "mise exec -- mix agent_code_x.check"
    remediation_plan: "SYM-149 adds the independent code/test conformance rule and X record."
    not_applicable_reason: ""
  - id: X-02
    threshold: false
    baseline_status: not_satisfied
    final_status: satisfied
    evidence: "test/symphony_elixir/agent_code_x_check_test.exs: layer validation fixtures"
    execution_kind: machine_check
    test_layer: 1
    execution: "mise exec -- mix agent_code_x.check"
    remediation_plan: "SYM-149 records one numbered layer per clause and checks the machine/runtime boundary."
    not_applicable_reason: ""
  - id: X-03
    threshold: false
    baseline_status: partially_satisfied
    final_status: satisfied
    evidence: "checkers section in this record; focused tests named by each checker row"
    execution_kind: machine_check
    test_layer: 1
    execution: "mise exec -- mix test test/mix/tasks/docs_check_task_test.exs test/scripts/negative_assertion_inventory_test.exs"
    remediation_plan: "SYM-149 adds the missing focused tests and finding-level calibration numbers."
    not_applicable_reason: ""
  - id: X-04
    threshold: true
    baseline_status: partially_satisfied
    final_status: satisfied
    evidence: "ratchet section in this record; mix.exs lint alias; test/mix/tasks/agent_code_x_check_task_test.exs"
    execution_kind: machine_check
    test_layer: 1
    execution: "mise exec -- mix lint"
    remediation_plan: "SYM-149 measures initial findings before gate wiring, clears them, and retains one hard path."
    not_applicable_reason: ""
  - id: X-05
    threshold: false
    baseline_status: not_satisfied
    final_status: satisfied
    evidence: "test/symphony_elixir/agent_code_x_check_test.exs: blank disposition fixtures"
    execution_kind: machine_check
    test_layer: 1
    execution: "mise exec -- mix agent_code_x.check"
    remediation_plan: "SYM-149 makes a remediation plan or not-applicable reason mandatory for unmet states."
    not_applicable_reason: ""
checkers:
  - id: "mix agent_code.check"
    test_layer: 1
    focused_test: test/mix/tasks/agent_code_check_task_test.exs
    disagreement_count: 0
    sample_count: 2
    disagreement_rate: 0.0
  - id: "mix agent_code_x.check"
    test_layer: 1
    focused_test: test/mix/tasks/agent_code_x_check_task_test.exs
    disagreement_count: 0
    sample_count: 8
    disagreement_rate: 0.0
  - id: "mix docs.check"
    test_layer: 1
    focused_test: test/mix/tasks/docs_check_task_test.exs
    disagreement_count: 0
    sample_count: 2
    disagreement_rate: 0.0
  - id: "mix docs.drift"
    test_layer: 1
    focused_test: test/mix/tasks/docs_drift_task_test.exs
    disagreement_count: 0
    sample_count: 2
    disagreement_rate: 0.0
  - id: "mix pr_body.check"
    test_layer: 1
    focused_test: test/mix/tasks/pr_body_check_test.exs
    disagreement_count: 0
    sample_count: 2
    disagreement_rate: 0.0
  - id: "mix specs.check"
    test_layer: 1
    focused_test: test/mix/tasks/specs_check_task_test.exs
    disagreement_count: 0
    sample_count: 2
    disagreement_rate: 0.0
  - id: scripts/docs_drift_pr_linkage.sh
    test_layer: 1
    focused_test: test/symphony_elixir/docs_drift_pr_linkage_test.exs
    disagreement_count: 0
    sample_count: 2
    disagreement_rate: 0.0
  - id: scripts/negative_assertion_inventory.exs
    test_layer: 1
    focused_test: test/scripts/negative_assertion_inventory_test.exs
    disagreement_count: 0
    sample_count: 2
    disagreement_rate: 0.0
ratchet:
  warning_command: "mise exec -- mix agent_code_x.check"
  warning_result: "FAIL clauses=5 checkers=8 failures=2 baseline_remaining=1; X-02.test_layer was the one exact content finding"
  manual_sample_count: 8
  initial_findings:
    - X-02.test_layer
  initial_finding_count: 1
  false_positive_count: 0
  false_positive_rate: 0.0
  baseline_remaining: 0
  hardening_criterion: baseline_remaining=0
  hardening_event: "X-02.test_layer was set to Layer 1, the active baseline and allowance were removed, and the checker entered mix lint."
status_counts:
  satisfied: 5
  partially_satisfied: 0
  not_satisfied: 0
  not_applicable: 0
```
<!-- agent-code-x-record:end -->

The warning stage is the checker run against the repository before `mix lint` invokes it. Its
non-zero result identifies the exact initial stock while the existing gate remains unchanged. New
findings have no exemption route. Hardening occurs only at `baseline_remaining=0`; at that event the
active baseline and its reporting allowance are absent, and only the single hard-gate path remains.

Final status totals come from the five `final_status` values in the machine record. The checker
recomputes those totals and the calibration ratios, verifies every focused test path, and reports a
stable one-line waterline.

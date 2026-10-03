defmodule SymphonyElixir.AgentCodeXCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentCodeXCheck

  setup do
    root = Path.join(System.tmp_dir!(), "agent-code-x-check-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/focused_test.exs"), "# focused fixture\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepts the complete record and emits one deterministic waterline", %{root: root} do
    write_record(root, record())

    report = AgentCodeXCheck.check(root: root)

    assert report["status"] == "pass"
    assert report["errors"] == []
    assert report["summary"] == %{"clauses" => 5, "checkers" => 8, "failures" => 0}

    assert AgentCodeXCheck.human_output(report) ==
             "agent_code_x.check: PASS clauses=5 checkers=8 failures=0 baseline_remaining=0"
  end

  test "locates missing, duplicate, and unexpected clauses by identity", %{root: root} do
    [x01, x02, _x03, x04, x05] = record()["clauses"]
    changed = put_in(record(), ["clauses"], [x01, x02, x02, x04, x05, Map.put(x01, "id", "X-06")])
    write_record(root, changed)

    assert AgentCodeXCheck.check(root: root)["errors"] == [
             "\"X-06\": unexpected clause",
             "X-02: duplicate clause",
             "X-03: missing clause",
             "status_counts.satisfied: expected 6, got 5"
           ]
  end

  test "rejects a threshold without one numbered test layer", %{root: root} do
    changed = update_clause(record(), "X-02", &Map.delete(&1, "test_layer"))
    write_record(root, changed)

    errors = AgentCodeXCheck.check(root: root)["errors"]
    assert "X-02.fields: expected exactly #{inspect(Enum.sort(clause_keys()))}, got #{inspect(Enum.sort(clause_keys() -- ["test_layer"]))}" in errors
    assert "X-02.test_layer: expected one of 1, 2, 3, 4" in errors
  end

  test "enforces the machine and runtime layer boundary", %{root: root} do
    machine = update_clause(record(), "X-02", &Map.put(&1, "test_layer", 3))
    write_record(root, machine)
    assert "X-02.test_layer: machine_check requires Layer 1 or 2" in AgentCodeXCheck.check(root: root)["errors"]

    runtime =
      record()
      |> update_clause("X-02", &Map.put(&1, "execution_kind", "runtime_behavior"))
      |> update_clause("X-02", &Map.put(&1, "test_layer", 2))

    write_record(root, runtime)
    assert "X-02.test_layer: runtime_behavior requires Layer 3 or 4" in AgentCodeXCheck.check(root: root)["errors"]
  end

  test "requires every checker to be Layer 1 with a focused test and exact calibration arithmetic", %{root: root} do
    changed =
      record()
      |> update_checker("mix docs.check", &Map.put(&1, "test_layer", 2))
      |> update_checker("mix docs.check", &Map.put(&1, "focused_test", "test/missing.exs"))
      |> update_checker("mix docs.check", &Map.put(&1, "disagreement_count", 1))

    write_record(root, changed)

    assert AgentCodeXCheck.check(root: root)["errors"] == [
             "mix docs.check.disagreement_rate: expected 0.5",
             "mix docs.check.focused_test: file not found: test/missing.exs",
             "mix docs.check.test_layer: checker must be Layer 1"
           ]
  end

  test "rejects incomplete calibration and a nonzero hard-gate waterline", %{root: root} do
    changed =
      record()
      |> put_in(["ratchet", "initial_finding_count"], 2)
      |> put_in(["ratchet", "false_positive_count"], 1)
      |> put_in(["ratchet", "baseline_remaining"], 1)

    write_record(root, changed)

    assert AgentCodeXCheck.check(root: root)["errors"] == [
             "ratchet.baseline_remaining: hard gate requires 0, got 1",
             "ratchet.false_positive_rate: expected 0.125",
             "ratchet.initial_finding_count: expected 1"
           ]
  end

  test "X-05 rejects blank remediation plans for partial and unsatisfied states", %{root: root} do
    for status <- ["partially_satisfied", "not_satisfied"] do
      changed =
        record()
        |> update_clause("X-05", &Map.put(&1, "baseline_status", status))
        |> update_clause("X-05", &Map.put(&1, "remediation_plan", "  "))

      write_record(root, changed)
      assert "X-05.remediation_plan: must be non-empty" in AgentCodeXCheck.check(root: root)["errors"]
    end
  end

  test "X-05 rejects a blank not-applicable reason", %{root: root} do
    changed =
      record()
      |> update_clause("X-05", &Map.put(&1, "final_status", "not_applicable"))
      |> update_clause("X-05", &Map.put(&1, "not_applicable_reason", ""))
      |> put_in(["status_counts"], %{
        "satisfied" => 4,
        "partially_satisfied" => 0,
        "not_satisfied" => 0,
        "not_applicable" => 1
      })

    write_record(root, changed)
    assert "X-05.not_applicable_reason: must be non-empty" in AgentCodeXCheck.check(root: root)["errors"]
  end

  defp record do
    %{
      "schema" => "agent-facing-code-x-conformance",
      "clauses" => Enum.map(~w(X-01 X-02 X-03 X-04 X-05), &clause/1),
      "checkers" => Enum.map(checker_ids(), &checker/1),
      "ratchet" => %{
        "warning_command" => "mix agent_code_x.check",
        "warning_result" => "one initial finding",
        "manual_sample_count" => 8,
        "initial_findings" => ["X-02.test_layer"],
        "initial_finding_count" => 1,
        "false_positive_count" => 0,
        "false_positive_rate" => 0.0,
        "baseline_remaining" => 0,
        "hardening_criterion" => "baseline_remaining=0",
        "hardening_event" => "The initial finding was corrected before gate wiring."
      },
      "status_counts" => %{
        "satisfied" => 5,
        "partially_satisfied" => 0,
        "not_satisfied" => 0,
        "not_applicable" => 0
      }
    }
  end

  defp clause(id) do
    %{
      "id" => id,
      "threshold" => id == "X-04",
      "baseline_status" => "partially_satisfied",
      "final_status" => "satisfied",
      "evidence" => "focused fixture",
      "execution_kind" => "machine_check",
      "test_layer" => 1,
      "execution" => "mix agent_code_x.check",
      "remediation_plan" => "Complete the X checker and hard gate in SYM-149.",
      "not_applicable_reason" => ""
    }
  end

  defp checker(id) do
    %{
      "id" => id,
      "test_layer" => 1,
      "focused_test" => "test/focused_test.exs",
      "disagreement_count" => 0,
      "sample_count" => 2,
      "disagreement_rate" => 0.0
    }
  end

  defp checker_ids do
    [
      "mix agent_code.check",
      "mix agent_code_x.check",
      "mix docs.check",
      "mix docs.drift",
      "mix pr_body.check",
      "mix specs.check",
      "scripts/docs_drift_pr_linkage.sh",
      "scripts/negative_assertion_inventory.exs"
    ]
  end

  defp clause_keys do
    ~w(id threshold baseline_status final_status evidence execution_kind test_layer execution remediation_plan not_applicable_reason)
  end

  defp update_clause(record, id, fun) do
    update_in(record, ["clauses"], &Enum.map(&1, fn clause -> if clause["id"] == id, do: fun.(clause), else: clause end))
  end

  defp update_checker(record, id, fun) do
    update_in(record, ["checkers"], &Enum.map(&1, fn checker -> if checker["id"] == id, do: fun.(checker), else: checker end))
  end

  defp write_record(root, record) do
    File.write!(
      Path.join(root, "docs/agent-facing-code-x-conformance.md"),
      "<!-- agent-code-x-record:start -->\n```yaml\n#{Jason.encode!(record)}\n```\n<!-- agent-code-x-record:end -->\n"
    )
  end
end

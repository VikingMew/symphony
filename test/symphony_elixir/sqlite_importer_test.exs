defmodule SymphonyElixir.SQLiteImporterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SQLiteImporter

  test "normalizes legacy success aliases and clears failure fields" do
    assert SQLiteImporter.normalize_run(%{
             "status" => "succeeded",
             "failure_reason" => "ignored"
           }) == %{
             "status" => "completed",
             "failure_reason" => nil,
             "failure_evidence" => nil
           }
  end

  test "normalizes known, recognizable, opaque, and missing terminal reasons" do
    assert SQLiteImporter.normalize_run(%{
             "status" => "failed",
             "failure_reason" => "runtime_failure"
           })["failure_evidence"] == %{"import" => "historical_classification"}

    assert SQLiteImporter.normalize_run(%{
             "status" => "failed",
             "failure_reason" => "assignment_expired"
           })["failure_evidence"] == %{"import" => "historical_classification"}

    assert SQLiteImporter.normalize_run(%{
             "status" => "blocked",
             "failure_reason" => "checkout timed_out"
           }) == %{
             "status" => "blocked",
             "failure_reason" => "source_preparation_timeout",
             "failure_evidence" => %{
               "import" => "historical_mapping",
               "legacy_failure_reason" => "checkout timed_out",
               "phase" => "checkout"
             }
           }

    assert SQLiteImporter.normalize_run(%{
             "status" => "cancelled",
             "failure_reason" => "opaque"
           })["failure_evidence"] == %{
             "import" => "unclassified_legacy_reason",
             "legacy_failure_reason" => "opaque"
           }

    assert SQLiteImporter.normalize_run(%{"status" => "stopped", "failure_reason" => nil}) == %{
             "status" => "stopped",
             "failure_reason" => "unknown",
             "failure_evidence" => %{"import" => "missing_failure_reason"}
           }
  end

  test "rejects a status outside the cutover vocabulary" do
    assert_raise RuntimeError, ~s(Unknown legacy run status: "mystery"), fn ->
      SQLiteImporter.normalize_run(%{"status" => "mystery", "failure_reason" => nil})
    end
  end
end

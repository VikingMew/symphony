defmodule SymphonyElixir.ObservabilityDocumentationTest do
  use ExUnit.Case, async: true

  @logs_command "tail -F log/symphony.log.[0-9]* | jq -c"
  @trace_command ~S(curl -fsS -H "Authorization: Bearer $SYMPHONY_API_TOKEN" "$SYMPHONY_BASE_URL/api/v1/runs?issue_identifier=$ISSUE_IDENTIFIER")
  @metrics_command ~S(curl -fsS -H "Authorization: Bearer $SYMPHONY_API_TOKEN" "$SYMPHONY_BASE_URL/api/v1/state")

  test "operator documentation exposes one canonical command per surface" do
    logging = File.read!("docs/logging.md")

    assert occurrences(logging, @logs_command) == 1
    assert occurrences(logging, @trace_command) == 1
    assert occurrences(logging, @metrics_command) == 1
    assert logging =~ "Set `SYMPHONY_BASE_URL`"
    assert logging =~ "`SYMPHONY_API_TOKEN`"
  end

  test "observability owner is registered and defers terminal classification" do
    design = File.read!("docs/observability-errors-design.md")
    design_index = File.read!("docs/design.md")
    docs_index = File.read!("docs/README.md")
    alignment = File.read!("docs/documentation-alignment.md")

    assert design =~ "remain solely owned by\n[Run Failure Classification Design]"
    assert design_index =~ "[observability-errors-design.md]"
    assert docs_index =~ "[observability-errors-design.md]"
    assert docs_index =~ "[agent-facing-code-o-conformance.md]"
    assert alignment =~ "| Structured logs and request/tool error correlation |"
    assert alignment =~ "remain solely owned by `docs/run-failure-classification-design.md`"
  end

  defp occurrences(content, needle) do
    content
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end

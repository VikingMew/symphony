defmodule SymphonyElixir.Worker.PayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Payload

  test "accepts the versioned opaque execution contract" do
    assert {:ok, payload} = Payload.parse(valid_payload())
    assert payload.repository == "https://example.test/repo.git"
    assert Enum.map(payload.gates, & &1.command) == ["make all"]
    refute Map.has_key?(Map.from_struct(payload), :workflow_version_id)
  end

  test "rejects missing gates and unsupported versions" do
    assert {:error, {:invalid_execution_payload, _}} = Payload.parse(Map.delete(valid_payload(), "required_gates"))
    assert {:error, {:invalid_execution_payload, _}} = Payload.parse(%{"version" => 2})
  end

  defp valid_payload do
    %{
      "version" => 1,
      "repository" => "https://example.test/repo.git",
      "revision" => "main",
      "branch" => "work",
      "hooks" => [],
      "codex" => %{"command" => "codex app-server", "timeout_seconds" => 60},
      "required_gates" => [%{"command" => "make all", "timeout_seconds" => 600}],
      "handoff" => %{"command" => "handoff", "timeout_seconds" => 60}
    }
  end
end

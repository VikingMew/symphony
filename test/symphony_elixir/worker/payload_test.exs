defmodule SymphonyElixir.Worker.PayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Payload

  test "accepts the versioned opaque execution contract" do
    assert {:ok, payload} = Payload.parse(valid_payload())
    assert payload.repository == "https://example.test/repo.git"
    assert payload.codex.prompt == "Implement the task."
    assert payload.codex.issue == %{identifier: "SYM-45", title: "Align worker payloads"}
    assert Enum.map(payload.gates, & &1.command) == ["scripts/check.sh"]
    refute Map.has_key?(Map.from_struct(payload), :workflow_version_id)
  end

  test "rejects missing gates and unsupported versions" do
    assert {:error, {:invalid_execution_payload, _}} = Payload.parse(Map.delete(valid_payload(), "required_gates"))
    assert {:error, {:invalid_execution_payload, _}} = Payload.parse(%{"version" => 2})
  end

  test "accepts an empty required gates list" do
    assert {:ok, payload} = Payload.parse(Map.put(valid_payload(), "required_gates", []))
    assert payload.gates == []
  end

  test "preserves validation of configured gates" do
    invalid = Map.put(valid_payload(), "required_gates", [%{"command" => "", "timeout_seconds" => 600}])

    assert {:error, {:invalid_execution_payload, _}} = Payload.parse(invalid)
  end

  test "rejects credentials and workflow version fields anywhere in the payload" do
    assert {:error, {:invalid_execution_payload, "forbidden field token"}} =
             Payload.parse(Map.put(valid_payload(), "token", "secret"))

    assert {:error, {:invalid_execution_payload, "forbidden field workflow_version_id"}} =
             Payload.parse(Map.put(valid_payload(), "workflow_version_id", "old"))

    assert {:error, {:invalid_execution_payload, "repository credentials are forbidden"}} =
             valid_payload()
             |> Map.put("repository", "https://user:pass@example.test/repo.git")
             |> Payload.parse()
  end

  defp valid_payload do
    %{
      "version" => 1,
      "repository" => "https://example.test/repo.git",
      "revision" => "main",
      "branch" => "work",
      "hooks" => [],
      "codex" => %{
        "command" => "codex app-server",
        "pre_start_commands" => [],
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write",
        "turn_sandbox_policy" => nil,
        "turn_timeout_ms" => 60_000,
        "read_timeout_ms" => 5_000,
        "stall_timeout_ms" => 30_000,
        "prompt" => "Implement the task.",
        "profile" => "implementation",
        "issue" => %{"identifier" => "SYM-45", "title" => "Align worker payloads"}
      },
      "required_gates" => [%{"command" => "scripts/check.sh", "timeout_seconds" => 600}],
      "handoff" => %{"command" => "handoff", "timeout_seconds" => 60}
    }
  end
end

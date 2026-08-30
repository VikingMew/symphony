defmodule SymphonyElixir.Worker.ExecutionPayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.{ExecutionPayload, Payload}

  test "converts the Panel snapshot into the worker-v1 execution contract" do
    panel_payload = panel_payload()
    execution = ExecutionPayload.from_task_payload(panel_payload)

    assert execution["version"] == 1
    assert execution["repository"] == "https://example.test/repo.git"
    assert execution["revision"] == "main"
    assert execution["branch"] == "vikingmew-sym-45"
    assert execution["codex"]["timeout_seconds"] == 3_601
    assert execution["codex"]["command"] =~ "codex exec --json --"
    assert execution["codex"]["command"] =~ "Workflow profile: implementation"
    assert Enum.map(execution["hooks"], & &1["command"]) == ["mix setup", "mix test"]
    assert execution["required_gates"] == [%{"command" => "make all", "timeout_seconds" => 1_800}]
    assert execution["handoff"]["policy"] == panel_payload["handoff"]["policy"]
    assert execution["handoff"]["command"] =~ "SYMPHONY_HANDOFF_COMMIT"
    assert {:ok, parsed} = Payload.parse(execution)
    assert parsed.repository == "https://example.test/repo.git"

    refute Map.has_key?(execution, "issue")
    refute Map.has_key?(execution, "prompt")
    refute Map.has_key?(execution, "workflow_profile")
    assert panel_payload["issue"]["identifier"] == "SYM-45"
  end

  defp panel_payload do
    %{
      "issue" => %{
        "identifier" => "SYM-45",
        "title" => "Align worker payloads",
        "description" => "Keep the persisted Panel snapshot unchanged."
      },
      "prompt" => "Implement and validate the task.",
      "workflow_profile" => "implementation",
      "execution_mode" => "worker",
      "repository" => %{
        "url" => "https://example.test/repo.git",
        "source_ref" => "main",
        "implementation_branch" => "vikingmew-sym-45"
      },
      "required_gates" => [%{"name" => "make-all", "command" => "make all", "timeout_ms" => 1_800_000}],
      "hooks" => %{
        "after_create" => "mix setup",
        "before_run" => "mix test",
        "after_run" => nil,
        "before_remove" => nil,
        "timeout_ms" => 30_000
      },
      "limits" => %{"turn_timeout_ms" => 3_600_001},
      "codex" => %{"command" => "codex app-server"},
      "handoff" => %{"policy" => "push_pr_then_restricted_linear"}
    }
  end
end

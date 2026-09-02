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
    assert execution["codex"]["command"] == "codex app-server"
    assert execution["codex"]["turn_timeout_ms"] == 3_600_001
    assert execution["codex"]["issue"] == %{"identifier" => "SYM-45", "title" => "Align worker payloads"}
    assert execution["codex"]["prompt"] =~ "Workflow profile: implementation"
    assert execution["codex"]["prompt"] =~ "Linear issue SYM-45: Align worker payloads"
    assert Enum.map(execution["hooks"], & &1["command"]) == ["mix setup", "mix test"]

    assert Enum.map(execution["required_gates"], & &1["command"]) == [
             "scripts/check.sh",
             "scripts/unit.sh",
             "scripts/dialyzer.sh"
           ]

    assert execution["handoff"]["policy"] == panel_payload["handoff"]["policy"]
    refute Map.has_key?(execution["handoff"], "command")
    assert {:ok, parsed} = Payload.parse(execution)
    assert parsed.repository == "https://example.test/repo.git"
    assert parsed.codex.prompt == execution["codex"]["prompt"]
    assert parsed.codex.issue == %{identifier: "SYM-45", title: "Align worker payloads"}

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
      "required_gates" => [
        %{"name" => "check", "command" => "scripts/check.sh", "timeout_ms" => 300_000},
        %{"name" => "unit", "command" => "scripts/unit.sh", "timeout_ms" => 1_800_000},
        %{"name" => "dialyzer", "command" => "scripts/dialyzer.sh", "timeout_ms" => 1_800_000}
      ],
      "hooks" => %{
        "after_create" => "mix setup",
        "before_run" => "mix test",
        "after_run" => nil,
        "before_remove" => nil,
        "timeout_ms" => 30_000
      },
      "limits" => %{
        "turn_timeout_ms" => 3_600_001,
        "read_timeout_ms" => 5_000,
        "stall_timeout_ms" => 300_000
      },
      "codex" => %{
        "command" => "codex app-server",
        "pre_start_commands" => [],
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write",
        "turn_sandbox_policy" => nil
      },
      "handoff" => %{"policy" => "push_pr_then_restricted_linear"}
    }
  end
end

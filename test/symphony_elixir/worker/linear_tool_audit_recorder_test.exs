defmodule SymphonyElixir.Worker.LinearToolAuditRecorderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Worker.{Config, LinearToolAuditRecorder}

  defmodule Client do
    def event(config, identity, task_id, event_type, payload) do
      send(config.request_options[:test_pid], {:event, identity, task_id, event_type, payload})
      config.request_options[:outcome]
    end
  end

  test "forwards a redacted audit with worker identity and correlation" do
    context = context({:ok, %{}})
    recorder = &LinearToolAuditRecorder.record(context, &1, &2)

    response =
      DynamicTool.execute("linear_task_read", %{"api_token" => "secret"},
        issue_id: "issue-1",
        issue_identifier: "SYM-87",
        profile: "implementation",
        run_id: "run-1",
        session_id: "codex-session-1",
        audit_recorder: recorder,
        task_reader: fn _ -> {:ok, %{"identifier" => "SYM-87"}} end
      )

    assert response["success"]

    assert_receive {:event, identity, "task-1", "linear.tool_call", payload}
    assert identity == %{"worker_id" => "worker-1", "session_id" => "worker-session-1", "protocol_version" => "worker-api-v1"}
    assert payload.correlation == %{"run_id" => "run-1", "task_id" => "task-1"}
    assert payload.tool == "linear_task_read"
    assert payload.status == "success"
    assert payload.arguments["api_token"] == "[REDACTED]"
    assert payload.run_id == "run-1"
    assert payload.session_id == "codex-session-1"
  end

  test "transport failure is visible and does not replace the tool response" do
    recorder = &LinearToolAuditRecorder.record(context({:error, {:transport_error, :closed}}), &1, &2)

    log =
      capture_log(fn ->
        assert %{"success" => true} =
                 DynamicTool.execute("linear_task_read", %{},
                   issue_id: "issue-1",
                   issue_identifier: "SYM-87",
                   profile: "implementation",
                   run_id: "run-1",
                   session_id: "codex-session-1",
                   task_id: "task-1",
                   audit_recorder: recorder,
                   task_reader: fn _ -> {:ok, %{"identifier" => "SYM-87"}} end
                 )
      end)

    assert log =~ "action=continue_degraded"
    assert log =~ "tool=linear_task_read"
    assert log =~ "task_id=\"task-1\""
    assert log =~ "run_id=\"run-1\""
    assert log =~ "session_id=\"codex-session-1\""
    assert log =~ "transport_error"
  end

  test "forwards pull request and handoff audits with bounded proof evidence" do
    context = context({:ok, %{}})
    recorder = &LinearToolAuditRecorder.record(context, &1, &2)
    issue = %Issue{id: "issue-1", identifier: "SYM-87", branch_name: "feature/sym-87"}

    create_response =
      DynamicTool.execute("create_pull_request", %{"title" => "SYM-87: Ship", "body" => "body"},
        issue: issue,
        profile: "implementation",
        run_id: "run-create",
        session_id: "codex-session-1",
        pull_request_proof_secret: "proof-secret",
        audit_recorder: recorder,
        pull_request_creator: fn _issue, _rendered, _opts ->
          {:ok,
           %{
             url: "https://github.com/acme/app/pull/87",
             repository: "acme/app",
             base: "main",
             head: "feature/sym-87",
             head_oid: String.duplicate("b", 40),
             source: :gh
           }}
        end
      )

    assert create_response["success"]
    create_output = Jason.decode!(create_response["output"])
    assert_receive {:event, _identity, "task-1", "linear.tool_call", create_payload}
    assert create_payload.tool == "create_pull_request"
    assert create_payload.status == "success"
    assert create_payload.result["repository"] == "acme/app"
    refute inspect(create_payload) =~ "proof-secret"
    refute inspect(create_payload) =~ "completion_proof"

    handoff_payload = %{
      "comment" => "done",
      "result" => %{"validation" => "green"},
      "references" => %{
        "branch" => "feature/sym-87",
        "commit" => "abc123",
        "pr_url" => create_output["url"],
        "pr_proof" => create_output["completion_proof"]
      }
    }

    handoff_response =
      DynamicTool.execute("handoff", handoff_payload,
        profile: "implementation",
        run_id: "run-handoff",
        session_id: "codex-session-1",
        audit_recorder: recorder,
        pull_request_result: fn -> %{url: create_output["url"], completion_proof: create_output["completion_proof"]} end,
        handoff_submitter: fn _payload -> :ok end
      )

    assert handoff_response["success"]
    assert_receive {:event, _identity, "task-1", "linear.tool_call", handoff_audit}
    assert handoff_audit.tool == "handoff"
    assert handoff_audit.status == "success"
    assert handoff_audit.result == %{"accepted" => true, "linear_updated" => false}
    refute inspect(handoff_audit) =~ create_output["completion_proof"]
  end

  defp context(outcome) do
    config = %Config{
      panel_url: "http://panel.test",
      registration_token: "token",
      worker_name: "worker",
      workspace_root: "/tmp/workspaces",
      cache_root: "/tmp/cache",
      log_root: "/tmp/logs",
      request_options: [test_pid: self(), outcome: outcome]
    }

    %{
      client: Client,
      config: config,
      identity: %{"worker_id" => "worker-1", "session_id" => "worker-session-1", "protocol_version" => "worker-api-v1"},
      task_id: "task-1",
      correlation: %{"run_id" => "run-1", "task_id" => "task-1"}
    }
  end
end

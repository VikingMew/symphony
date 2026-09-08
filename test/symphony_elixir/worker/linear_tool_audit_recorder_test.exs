defmodule SymphonyElixir.Worker.LinearToolAuditRecorderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Codex.DynamicTool
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

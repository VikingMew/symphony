defmodule SymphonyElixir.Worker.ExecutorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Worker.{Config, ExecutionPayload, Executor, Payload}

  test "includes the repository project in the worker workflow context" do
    assert {:ok, payload} = panel_payload() |> ExecutionPayload.from_task_payload() |> Payload.parse()

    config = %Config{
      panel_url: "http://panel.test",
      registration_token: "worker-token",
      worker_name: "worker-test",
      workspace_root: "/tmp/symphony-workspaces",
      cache_root: "/tmp/symphony-cache",
      log_root: "/tmp/symphony-logs"
    }

    workflow = Executor.codex_workflow(config, %{config: %{}}, payload)

    assert workflow.config["project"]["repository_url"] ==
             "git@github.com:VikingMew/symphony.git"

    assert workflow.config["project"]["default_branch"] == "main"
    assert {:ok, settings} = Schema.parse(workflow.config)
    assert settings.project.repository_url == "git@github.com:VikingMew/symphony.git"
  end

  defp panel_payload do
    %{
      "issue" => %{"identifier" => "SYM-68", "title" => "Propagate project config"},
      "prompt" => "Implement the task.",
      "workflow_profile" => "implementation",
      "repository" => %{
        "url" => "git@github.com:VikingMew/symphony.git",
        "source_ref" => "main",
        "implementation_branch" => "vikingmew-sym-68"
      },
      "hooks" => %{
        "after_create" => nil,
        "before_run" => nil,
        "after_run" => nil,
        "before_remove" => nil,
        "timeout_ms" => 1_000
      },
      "codex" => %{
        "command" => "codex app-server",
        "pre_start_commands" => [],
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write",
        "turn_sandbox_policy" => nil
      },
      "limits" => %{"turn_timeout_ms" => 60_000, "read_timeout_ms" => 5_000, "stall_timeout_ms" => 30_000},
      "required_gates" => [],
      "handoff" => %{}
    }
  end
end

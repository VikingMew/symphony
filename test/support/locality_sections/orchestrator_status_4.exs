# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.OrchestratorStatusTest.Sections.OrchestratorStatus4 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      alias SymphonyElixir.Codex.MessageHumanizer

      import ExUnit.CaptureLog
      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Health
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.TestSupport.FakePersistence
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Worker.HeartbeatMetrics
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          ensure_panel_children_running!: 0,
          panel_supervisor_running?: 0,
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      alias SymphonyElixir.OrchestratorStatusTest.RollbackLinearClient

      test "status dashboard repeated snapshot refreshes preserve Orchestrator state" do
        orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)
        dashboard_name = Module.concat(__MODULE__, :RepeatedSnapshotDashboard)

        {:ok, dashboard_pid} =
          Elixir.SymphonyElixir.StatusDashboard.start_link(
            name: dashboard_name,
            enabled: true,
            refresh_ms: 60_000
          )

        on_exit(fn ->
          if Process.alive?(dashboard_pid) do
            Process.exit(dashboard_pid, :normal)
          end
        end)

        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(orchestrator_pid)

        Enum.each(1..3, fn _ ->
          Elixir.SymphonyElixir.StatusDashboard.notify_update(dashboard_name)
          send(dashboard_pid, :tick)
        end)

        _ = :sys.get_state(dashboard_pid)
        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(orchestrator_pid)
        assert Process.alive?(orchestrator_pid)
      end

      test "application configures a rotating file logger handler" do
        assert {:ok, handler_config} = :logger.get_handler_config(:symphony_disk_log)
        assert handler_config.module == :logger_disk_log_h

        disk_config = handler_config.config
        assert disk_config.type == :wrap
        assert is_list(disk_config.file)
        assert disk_config.max_no_bytes > 0
        assert disk_config.max_no_files > 0
      end

      test "application keeps the default console logger handler" do
        assert {:ok, handler_config} = :logger.get_handler_config(:default)
        assert handler_config.formatter == {:logger_formatter, %{single_line: true}}
        assert handler_config.level == :info
      end

      test "status dashboard humanizes full codex app-server event set" do
        event_cases = [
          {"turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}, "turn started"},
          {"turn/completed", %{"params" => %{"turn" => %{"status" => "completed"}}}, "turn completed"},
          {"turn/diff/updated", %{"params" => %{"diff" => "line1\nline2"}}, "turn diff updated"},
          {"turn/plan/updated", %{"params" => %{"plan" => [%{"step" => "a"}, %{"step" => "b"}]}}, "plan updated"},
          {"thread/tokenUsage/updated",
           %{
             "params" => %{
               "usage" => %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11}
             }
           }, "thread token usage updated"},
          {"item/started",
           %{
             "params" => %{
               "item" => %{
                 "id" => "item-1234567890abcdef",
                 "type" => "commandExecution",
                 "status" => "running"
               }
             }
           }, "item started: command execution"},
          {"item/completed", %{"params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}}, "item completed: file change"},
          {"item/agentMessage/delta", %{"params" => %{"delta" => "hello"}}, "agent message streaming"},
          {"item/plan/delta", %{"params" => %{"delta" => "step"}}, "plan streaming"},
          {"item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "thinking"}}, "reasoning summary streaming"},
          {"item/reasoning/summaryPartAdded", %{"params" => %{"summaryText" => "section"}}, "reasoning summary section added"},
          {"item/reasoning/textDelta", %{"params" => %{"textDelta" => "reason"}}, "reasoning text streaming"},
          {"item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "ok"}}, "command output streaming"},
          {"item/fileChange/outputDelta", %{"params" => %{"outputDelta" => "changed"}}, "file change output streaming"},
          {"item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => "git status"}}, "command approval requested (git status)"},
          {"item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 2}}, "file change approval requested (2 files)"},
          {"item/tool/call", %{"params" => %{"tool" => "linear_graphql"}}, "dynamic tool call requested (linear_graphql)"},
          {"item/tool/requestUserInput", %{"params" => %{"question" => "Continue?"}}, "tool requires user input: Continue?"},
          {"mcpServer/elicitation/request",
           %{
             "params" => %{
               "serverName" => "linear",
               "toolName" => "task_update",
               "prompt" => "Approve state change?"
             }
           }, "MCP elicitation requested (server: linear, tool: task_update, prompt: Approve state change?)"}
        ]

        Enum.each(event_cases, fn {method, payload, expected_fragment} ->
          message = Map.put(payload, "method", method)

          humanized =
            Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(%{
              event: :notification,
              message: message
            })

          assert humanized =~ expected_fragment
        end)
      end

      test "status dashboard humanizes mcp elicitation turn blockers with server and tool" do
        message = %{
          event: :turn_input_required,
          message: %{
            payload: %{
              "method" => "mcpServer/elicitation/request",
              "params" => %{
                "serverName" => "linear",
                "request" => %{"toolName" => "task_comment"},
                "message" => "Confirm comment update?"
              }
            }
          }
        }

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(message) ==
                 "MCP elicitation requested (server: linear, tool: task_comment, prompt: Confirm comment update?)"
      end

      test "status dashboard humanizes dynamic tool wrapper events" do
        completed = %{
          event: :tool_call_completed,
          message: %{
            payload: %{"method" => "item/tool/call", "params" => %{"name" => "linear_graphql"}}
          }
        }

        failed = %{
          event: :tool_call_failed,
          message: %{
            payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}}
          }
        }

        unsupported = %{
          event: :unsupported_tool_call,
          message: %{
            payload: %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
          }
        }

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(completed) =~
                 "dynamic tool call completed (linear_graphql)"

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(failed) =~
                 "dynamic tool call failed (linear_graphql)"

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(unsupported) =~
                 "unsupported dynamic tool call rejected (unknown_tool)"
      end

      test "status dashboard unwraps nested codex payload envelopes" do
        wrapped = %{
          event: :notification,
          message: %{
            payload: %{
              "method" => "turn/completed",
              "params" => %{
                "turn" => %{"status" => "completed"},
                "usage" => %{"input_tokens" => "10", "output_tokens" => 2, "total_tokens" => 12}
              }
            },
            raw: "{\"method\":\"turn/completed\"}"
          }
        }

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(wrapped) =~
                 "turn completed"

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(wrapped) =~ "in 10"
      end

      test "status dashboard uses shell command line as exec command status text" do
        message = %{
          event: :notification,
          message: %{
            "method" => "codex/event/exec_command_begin",
            "params" => %{"msg" => %{"command" => "git status --short"}}
          }
        }

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(message) ==
                 "git status --short"
      end

      test "status dashboard formats auto-approval updates from codex" do
        message = %{
          event: :approval_auto_approved,
          message: %{
            payload: %{
              "method" => "item/commandExecution/requestApproval",
              "params" => %{"parsedCmd" => "mix test"}
            },
            decision: "acceptForSession"
          }
        }

        humanized = Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(message)
        assert humanized =~ "command approval requested"
        assert humanized =~ "auto-approved"
      end

      test "status dashboard formats auto-answered tool input updates from codex" do
        message = %{
          event: :tool_input_auto_answered,
          message: %{
            payload: %{
              "method" => "item/tool/requestUserInput",
              "params" => %{"question" => "Continue?"}
            },
            answer: "This is a non-interactive session. Operator input is unavailable."
          }
        }

        humanized = Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(message)
        assert humanized =~ "tool requires user input"
        assert humanized =~ "auto-answered"
      end

      test "status dashboard enriches wrapper reasoning and message streaming events with payload context" do
        reasoning_message = %{
          event: :notification,
          message: %{
            "method" => "codex/event/agent_reasoning",
            "params" => %{
              "msg" => %{
                "payload" => %{"summaryText" => "compare retry paths for Linear polling"}
              }
            }
          }
        }

        message_delta = %{
          event: :notification,
          message: %{
            "method" => "codex/event/agent_message_delta",
            "params" => %{
              "msg" => %{
                "payload" => %{"delta" => "writing workpad reconciliation update"}
              }
            }
          }
        }

        fallback_reasoning = %{
          event: :notification,
          message: %{
            "method" => "codex/event/agent_reasoning",
            "params" => %{"msg" => %{"payload" => %{}}}
          }
        }

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(reasoning_message) =~
                 "reasoning update: compare retry paths for Linear polling"

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(message_delta) =~
                 "agent message streaming: writing workpad reconciliation update"

        assert Elixir.SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(fallback_reasoning) ==
                 "reasoning update"
      end

      test "application stop logs offline status" do
        log =
          capture_log(fn ->
            assert :ok = SymphonyElixir.Application.stop(:normal)
          end)

        assert log =~ "Symphony application offline"
      end

      defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
        deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end

      defp streaming_delta(fragment, timestamp) do
        %{
          event: :notification,
          payload: %{
            "method" => "codex/event/agent_message_delta",
            "params" => %{
              "msg" => %{
                "payload" => %{"delta" => fragment}
              }
            }
          },
          timestamp: timestamp
        }
      end

      defp restore_app_env(key, nil) do
        Application.delete_env(:symphony_elixir, key)
      end

      defp restore_app_env(key, value) do
        Application.put_env(:symphony_elixir, key, value)
      end

      defp use_noop_linear_client do
        previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)

        Application.put_env(
          :symphony_elixir,
          :linear_client_module,
          Elixir.SymphonyElixir.OrchestratorStatusTest.RollbackLinearClient
        )

        on_exit(fn ->
          restore_app_env(:linear_client_module, previous_linear_client)
        end)
      end

      defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
        snapshot = GenServer.call(pid, :snapshot)

        if predicate.(snapshot) do
          snapshot
        else
          if System.monotonic_time(:millisecond) >= deadline_ms do
            flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
          else
            Process.sleep(5)
            do_wait_for_snapshot(pid, predicate, deadline_ms)
          end
        end
      end
    end
  end
end

defmodule SymphonyElixir.RunHistoryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunHistory

  defmodule TestPersistence do
    @moduledoc false

    def put_events(events) do
      Application.put_env(:symphony_elixir, :run_history_test_events, events)
    end

    def list_events(opts) do
      :symphony_elixir
      |> Application.get_env(:run_history_test_events, [])
      |> filter_run(Keyword.get(opts, :run_id))
      |> sort_events(Keyword.get(opts, :order, :desc))
      |> Enum.take(Keyword.get(opts, :limit, 100))
    end

    defp filter_run(events, nil), do: events
    defp filter_run(events, run_id), do: Enum.filter(events, &(Map.get(&1, :run_id) == run_id))

    defp sort_events(events, :asc), do: Enum.sort_by(events, &Map.get(&1, :occurred_at))
    defp sort_events(events, _order), do: events |> sort_events(:asc) |> Enum.reverse()
  end

  defmodule RaisingPersistence do
    @moduledoc false

    def list_events(_opts), do: raise("events query failed")
  end

  setup do
    TestPersistence.put_events([])
    :ok
  end

  test "queries one run's session history without leaking sibling attempts" do
    t1 = ~U[2026-05-21 00:00:00Z]
    t2 = ~U[2026-05-21 00:00:01Z]

    TestPersistence.put_events([
      %{run_id: "run-b", event_type: "run.failed", payload: %{"message" => "other"}, occurred_at: t2},
      %{run_id: "run-a", event_type: "run.phase", payload: %{"phase" => "workspace_preparing", "status" => "started"}, occurred_at: t1}
    ])

    assert [
             %{
               at: ^t1,
               event: "run.phase",
               label: "Run phase started",
               detail: "workspace_preparing started",
               source: :system
             }
           ] = RunHistory.list_run_session_events(TestPersistence, "run-a")
  end

  test "returns a typed error instead of empty history when event reads fail" do
    assert {:error, {:query_failed, %RuntimeError{message: "events query failed"}}} =
             RunHistory.list_run_session_events(RaisingPersistence, "run-a")
  end

  test "transforms workspace and codex-style events into readable rows" do
    events = [
      %{
        event_type: "workspace.hook_output",
        payload: %{"hook" => "project_bootstrap", "output" => String.duplicate("clone ", 300)},
        occurred_at: ~U[2026-05-21 00:00:01Z]
      },
      %{
        event_type: "codex.event",
        payload: %{"message" => %{"msg" => %{"type" => "session_configured"}}},
        occurred_at: ~U[2026-05-21 00:00:02Z]
      }
    ]

    [workspace, codex] = RunHistory.from_events(events)

    assert workspace.label == "Workspace project_bootstrap output"
    assert workspace.source == :system
    assert workspace.operation == "project_bootstrap"
    assert String.length(workspace.metadata["output"]) <= 803

    assert codex.source == :agent
    assert codex.label == "Codex event"
  end

  test "transforms persisted codex updates through the codex humanizer" do
    [input_required, startup_failed] =
      RunHistory.from_events([
        %{
          event_type: "codex.update",
          payload: %{
            "event" => "turn_input_required",
            "message" => %{"method" => "turn/input_required", "params" => %{"reason" => "blocked"}}
          },
          occurred_at: ~U[2026-05-21 00:00:01Z]
        },
        %{
          event_type: "codex.update",
          payload: %{
            event: :startup_failed,
            message: %{reason: :response_error, response_error: %{"message" => "unknown variant reject"}}
          },
          occurred_at: ~U[2026-05-21 00:00:02Z]
        }
      ])

    assert input_required.label == "Codex turn input required"
    assert input_required.detail == "turn blocked: waiting for user input"
    assert startup_failed.label == "Codex startup failed"
    assert startup_failed.detail =~ "startup failed"
    assert startup_failed.detail =~ "unknown variant reject"
  end

  test "humanizes improved persisted codex payload shape with payload fallback" do
    [tool_call] =
      RunHistory.from_events([
        %{
          event_type: "codex.update",
          payload: %{
            "event" => "notification",
            "message" => %{"method" => "item/tool/call", "params" => %{"tool" => "linear_task_read"}},
            "session_id" => "thread-1"
          },
          occurred_at: ~U[2026-05-21 00:00:01Z]
        }
      ])

    assert tool_call.detail == "dynamic tool call requested (linear_task_read)"
    assert tool_call.operation == "item/tool/call"
    refute tool_call.low_signal
  end

  test "coalesces repeated legacy empty codex notifications" do
    [empty] =
      RunHistory.from_events([
        %{event_type: "codex.update", payload: %{"event" => "notification", "message" => nil}, occurred_at: ~U[2026-05-21 00:00:01Z]},
        %{event_type: "codex.update", payload: %{"event" => "notification", "message" => nil}, occurred_at: ~U[2026-05-21 00:00:02Z]},
        %{event_type: "codex.update", payload: %{"event" => "notification", "message" => nil}, occurred_at: ~U[2026-05-21 00:00:03Z]}
      ])

    assert empty.low_signal
    assert empty.detail == "3 empty Codex notifications; detailed payload was not persisted"
    assert empty.metadata["_coalesced_count"] == 3
  end

  test "coalesces adjacent persisted agent message fragments" do
    [message] =
      RunHistory.from_events([
        %{
          event_type: "codex.update",
          payload: %{
            event: :notification,
            message: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "hello "}}
          },
          occurred_at: ~U[2026-05-21 00:00:01Z]
        },
        %{
          event_type: "codex.update",
          payload: %{
            event: :notification,
            message: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "world"}}
          },
          occurred_at: ~U[2026-05-21 00:00:02Z]
        }
      ])

    assert message.detail == "agent message streaming: hello world"
    assert message.metadata["_coalesced_count"] == 2
  end

  test "transforms terminal and Linear transition events" do
    [started, completed, stopped, transition] =
      RunHistory.from_events([
        %{event_type: "run.started", payload: %{}, occurred_at: ~U[2026-05-21 00:00:01Z]},
        %{event_type: "run.completed", payload: %{}, occurred_at: ~U[2026-05-21 00:00:02Z]},
        %{event_type: "run.stopped", payload: %{}, occurred_at: ~U[2026-05-21 00:00:03Z]},
        %{
          event_type: "linear.state_transition",
          payload: %{"from_state" => "Ready", "to_state" => "In Progress"},
          occurred_at: ~U[2026-05-21 00:00:04Z]
        }
      ])

    assert started.label == "Run started"
    assert completed.label == "Run completed"
    assert stopped.severity == :warning
    assert transition.detail == "Ready -> In Progress"
    assert transition.source == :linear
  end

  test "transforms Linear tool call audit events" do
    [success, failure] =
      RunHistory.from_events([
        %{
          event_type: "linear.tool_call",
          payload: %{
            "tool" => "linear_issue_create",
            "status" => "success",
            "result" => %{"identifier" => "CCR-10", "url" => "https://linear.app/acme/issue/CCR-10"}
          },
          occurred_at: ~U[2026-05-21 00:00:01Z]
        },
        %{
          event_type: "linear.tool_call",
          payload: %{
            "tool" => "linear_issue_create",
            "status" => "failure",
            "error" => %{"class" => "workflow_profile_unavailable", "message" => "Workflow profile is unavailable for this Codex session."}
          },
          occurred_at: ~U[2026-05-21 00:00:02Z]
        }
      ])

    assert success.label == "Linear tool success"
    assert success.detail == "linear_issue_create succeeded: CCR-10 https://linear.app/acme/issue/CCR-10"
    assert success.source == :linear
    assert success.severity == :info

    assert failure.label == "Linear tool failure"
    assert failure.detail == "linear_issue_create failed: workflow_profile_unavailable: Workflow profile is unavailable for this Codex session."
    assert failure.source == :linear
    assert failure.severity == :error
  end

  test "projects completed nap raw events into aligned readable history" do
    thread_id = "019e5515-c0e1-7092-907b-a2ecdc4c6857"
    turn_id = "019e5515-c147-7060-ad65-2da33d439cf7"

    history =
      RunHistory.from_events([
        %{
          event_type: "codex.update",
          payload: %{
            "event" => "notification",
            "message" => %{
              "method" => "item/completed",
              "params" => %{
                "completedAtMs" => 1_779_544_142_693,
                "item" => %{
                  "id" => "msg_0eb22a2fdc89e0f2016a11b04cbb40819189af729271fbbbc4",
                  "phase" => "final_answer",
                  "text" => "Created 4 Backlog Linear issues, read-only:\n\n- `CCR-29` Align client model derivation\n- `CCR-30` Remove unused crate",
                  "type" => "agentMessage"
                },
                "threadId" => thread_id,
                "turnId" => turn_id
              }
            }
          },
          occurred_at: ~U[2026-05-23 13:49:02Z]
        },
        %{
          event_type: "codex.update",
          payload: %{
            "event" => "notification",
            "message" => %{
              "method" => "thread/tokenUsage/updated",
              "params" => %{
                "threadId" => thread_id,
                "turnId" => turn_id,
                "tokenUsage" => "[REDACTED]"
              }
            },
            "debug" => %{
              "raw" =>
                Jason.encode!(%{
                  "method" => "thread/tokenUsage/updated",
                  "params" => %{
                    "threadId" => thread_id,
                    "turnId" => turn_id,
                    "tokenUsage" => %{
                      "total" => %{
                        "totalTokens" => 1_388_311,
                        "inputTokens" => 1_381_584,
                        "outputTokens" => 6_727
                      }
                    }
                  }
                })
            }
          },
          occurred_at: ~U[2026-05-23 13:49:02Z]
        },
        %{
          event_type: "codex.update",
          payload: %{
            "event" => "notification",
            "message" => %{
              "method" => "account/rateLimits/updated",
              "params" => %{
                "rateLimits" => %{
                  "primary" => %{"usedPercent" => 6, "windowDurationMins" => 300},
                  "secondary" => %{"usedPercent" => 61, "windowDurationMins" => 10080}
                }
              }
            }
          },
          occurred_at: ~U[2026-05-23 13:49:02Z]
        },
        %{
          event_type: "codex.update",
          payload: %{
            "event" => "notification",
            "message" => %{"method" => "thread/status/changed", "params" => %{"threadId" => thread_id, "status" => %{"type" => "idle"}}}
          },
          occurred_at: ~U[2026-05-23 13:49:02Z]
        },
        %{
          event_type: "codex.update",
          payload: %{
            "event" => "turn_completed",
            "message" => %{
              "method" => "turn/completed",
              "params" => %{
                "threadId" => thread_id,
                "turn" => %{
                  "id" => turn_id,
                  "status" => "completed",
                  "completedAt" => 1_779_544_142,
                  "durationMs" => 193_080
                }
              }
            }
          },
          occurred_at: ~U[2026-05-23 13:49:03Z]
        },
        %{event_type: "run.completed", payload: %{"failure_reason" => nil, "run_id" => "run-nap"}, occurred_at: ~U[2026-05-23 13:49:04Z]}
      ])

    final_answer = Enum.find(history, &String.starts_with?(&1.detail, "agent final answer:"))
    token_usage = Enum.find(history, &String.starts_with?(&1.detail, "thread token usage updated"))
    rate_limits = Enum.find(history, &String.starts_with?(&1.detail, "rate limits updated:"))
    thread_idle = Enum.find(history, &(&1.operation == "thread/status/changed"))
    turn_completed = Enum.find(history, &String.starts_with?(&1.detail, "turn completed"))
    run_completed = Enum.find(history, &(&1.event == "run.completed"))

    assert final_answer.at == DateTime.from_unix!(1_779_544_142_693, :millisecond)
    assert final_answer.detail =~ "agent final answer: Created 4 Backlog Linear issues"
    assert final_answer.metadata["thread_id"] == thread_id
    assert final_answer.metadata["turn_id"] == turn_id
    assert final_answer.metadata["session_id"] == "#{thread_id}-#{turn_id}"
    assert final_answer.metadata["item_id"] == "msg_0eb22a2fdc89e0f2016a11b04cbb40819189af729271fbbbc4"

    assert token_usage.detail == "thread token usage updated (total 1,388,311, in 1,381,584, out 6,727)"
    assert rate_limits.detail == "rate limits updated: primary 6% / 300m secondary 61% / 10080m"
    assert thread_idle.detail == "thread/status/changed"
    assert turn_completed.at == DateTime.from_unix!(1_779_544_142, :second)
    assert turn_completed.detail == "turn completed (completed) in 3.2m"
    assert turn_completed.metadata["turn_id"] == turn_id
    assert run_completed.label == "Run completed"

    summary = RunHistory.summarize(%{status: "completed", attempt: 0}, history)

    assert summary.final_message =~ "Created 4 Backlog Linear issues"
    assert summary.last_codex_detail =~ "agent final answer: Created 4 Backlog Linear issues"
    assert "#{thread_id}-#{turn_id}" in summary.sessions
    assert summary.evidence_quality == :complete
  end

  test "limit keeps the historical query bounded and chronological" do
    TestPersistence.put_events([
      %{run_id: "run-a", event_type: "run.phase", payload: %{"phase" => "two"}, occurred_at: ~U[2026-05-21 00:00:02Z]},
      %{run_id: "run-a", event_type: "run.phase", payload: %{"phase" => "one"}, occurred_at: ~U[2026-05-21 00:00:01Z]}
    ])

    assert [%{detail: "one"}] = RunHistory.list_run_session_events(TestPersistence, "run-a", limit: 1)
  end

  test "empty and malformed historical events remain readable" do
    assert [] = RunHistory.list_run_session_events(TestPersistence, "missing", limit: :bad)

    assert %{
             event: "",
             label: "",
             detail: "",
             metadata: %{}
           } = RunHistory.from_event(%{})
  end

  test "summarizes useful run history signals" do
    history =
      RunHistory.from_events([
        %{
          event_type: "codex.update",
          payload: %{"event" => "notification", "message" => %{"method" => "item/tool/call", "params" => %{"tool" => "linear_task_read"}}, "session_id" => "thread-1"},
          occurred_at: ~U[2026-05-21 00:00:01Z]
        },
        %{
          event_type: "codex.update",
          payload: %{"event" => "turn_input_required", "message" => %{"method" => "turn/input_required"}},
          occurred_at: ~U[2026-05-21 00:00:02Z]
        },
        %{
          event_type: "codex.update",
          payload: %{"event" => "notification", "message" => %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "Finished the task."}}},
          occurred_at: ~U[2026-05-21 00:00:03Z]
        },
        %{
          event_type: "linear.state_transition",
          payload: %{"from_state" => "In Progress", "to_state" => "In Review"},
          occurred_at: ~U[2026-05-21 00:00:04Z]
        }
      ])

    summary = RunHistory.summarize(%{status: "failed", attempt: 2, failure_reason: "needs input"}, history)

    assert summary.outcome == "failed attempt 2"
    assert summary.final_message == "Finished the task."
    assert summary.last_codex_detail == "agent message streaming: Finished the task."
    assert "dynamic tool call requested (linear_task_read)" in summary.actions
    assert "linear_task_read x1" in summary.tools
    assert "In Progress -> In Review" in summary.linear_updates
    assert "dynamic tool call requested (linear_task_read)" in summary.highlights
    assert "needs input" in summary.blockers
    assert "turn blocked: waiting for user input" in summary.blockers
    assert summary.sessions == ["thread-1"]
    assert summary.evidence_quality == :complete
  end
end

defmodule SymphonyElixir.StatusDashboardLogTest do
  use SymphonyElixir.TestSupport

  @terminal_columns 115

  test "idle dashboard renders line-oriented status logs" do
    rendered =
      idle_snapshot()
      |> render_status(0.0)
      |> strip_ansi()

    assert rendered =~ ~S|level=info source=summary entity=runtime message="runtime snapshot"|
    assert rendered =~ ~S|agents="0/10"|
    assert rendered =~ ~S|retrying="0"|
    assert rendered =~ ~S|tokens="in 0 out 0 total 0"|
    assert rendered =~ ~S|source=linear entity=project message="https://linear.app/project/project/issues"|
    assert rendered =~ ~S|source=dashboard entity=url message="n/a"|
    assert rendered =~ ~S|source=codex entity=agents message="no active agents"|
    assert rendered =~ ~S|source=retry entity=queue message="no issues backing off"|

    refute_tui_chrome(rendered)
  end

  test "dashboard url renders as a log line when server port is configured" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    rendered =
      idle_snapshot()
      |> render_status(0.0)
      |> strip_ansi()

    assert rendered =~ ~S|source=dashboard entity=url message="http://127.0.0.1:4000/"|
    refute_tui_chrome(rendered)
  end

  test "running agents render as individual log lines with compact metadata" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-101",
             codex_total_tokens: 120_450,
             runtime_seconds: 785,
             turn_count: 11,
             last_codex_event: "turn_completed",
             last_codex_message: turn_completed_message("completed")
           }),
           running_entry(%{
             identifier: "MT-102",
             session_id: "thread-abcdef1234567890",
             codex_app_server_pid: "5252",
             codex_total_tokens: 89_200,
             runtime_seconds: 412,
             turn_count: 4,
             last_codex_event: "codex/event/task_started",
             last_codex_message: exec_command_message("mix test --cover")
           })
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 250_000,
           output_tokens: 18_500,
           total_tokens: 268_500,
           seconds_running: 4_321
         },
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 12_345, limit: 20_000, reset_in_seconds: 30},
           secondary: %{remaining: 45, limit: 60, reset_in_seconds: 12},
           credits: %{has_credits: true, balance: 9_876.5}
         }
       }}

    rendered =
      snapshot_data
      |> render_status(1_842.7)
      |> strip_ansi()

    assert rendered =~ ~S|agents="2/10"|
    assert rendered =~ ~S|throughput="1,842 tps"|
    assert rendered =~ ~S<source=codex entity=rate_limits message="gpt-5 | primary 12,345/20,000 reset 30s | secondary 45/60 reset 12s | credits 9876.50">
    assert rendered =~ ~S|source=codex entity=MT-101 message="turn completed (completed)"|
    assert rendered =~ ~S|event="turn_completed"|
    assert rendered =~ ~S|runtime="13m 5s / 11"|
    assert rendered =~ ~S|tokens="120,450"|
    assert rendered =~ ~S|source=codex entity=MT-102 message="mix test --cover"|
    assert rendered =~ ~S|pid="5252"|
    assert rendered =~ ~S|session="thre...567890"|
    assert rendered =~ ~S|source=retry entity=queue message="no issues backing off"|

    refute_tui_chrome(rendered)
  end

  test "retry queue renders every retry as warning log lines and sanitizes newlines" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-638",
             state: "retrying",
             codex_total_tokens: 14_200,
             runtime_seconds: 1_225,
             turn_count: 7,
             last_codex_event: :notification,
             last_codex_message: agent_message_delta("waiting on rate-limit backoff window")
           })
         ],
         retrying: [
           retry_entry(%{identifier: "MT-450", attempt: 4, due_in_ms: 1_250, error: "rate limit exhausted"}),
           retry_entry(%{identifier: "MT-451", attempt: 2, due_in_ms: 3_900, error: "retrying after API timeout with jitter"}),
           retry_entry(%{identifier: "MT-452", attempt: 6, due_in_ms: 8_100, error: "worker crashed\nrestarting cleanly"}),
           retry_entry(%{
             identifier: "MT-453",
             attempt: 1,
             due_in_ms: 11_000,
             error: "fourth queued retry should also render after removing the top-three limit"
           })
         ],
         codex_totals: %{input_tokens: 18_000, output_tokens: 2_200, total_tokens: 20_200, seconds_running: 2_700},
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 0, limit: 20_000, reset_in_seconds: 95},
           secondary: %{remaining: 0, limit: 60, reset_in_seconds: 45},
           credits: %{has_credits: false}
         }
       }}

    rendered =
      snapshot_data
      |> render_status(15.4)
      |> strip_ansi()

    assert rendered =~ ~S|level=warning source=codex entity=MT-638|
    assert rendered =~ ~S|message="agent message streaming: waiting on rate-limit backoff window"|
    assert rendered =~ ~S|level=warning source=retry entity=MT-450 message="rate limit exhausted" attempt="4" due_in="1.250s"|
    assert rendered =~ ~S|level=warning source=retry entity=MT-451 message="retrying after API timeout with jitter" attempt="2" due_in="3.900s"|
    assert rendered =~ ~S|level=warning source=retry entity=MT-452 message="worker crashed restarting cleanly" attempt="6" due_in="8.100s"|
    assert rendered =~ ~S|level=warning source=retry entity=MT-453 message="fourth queued retry should also render after removing the top-three limit"|

    retry_lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, "source=retry entity=MT-"))
    assert length(retry_lines) == 4
    refute Enum.any?(retry_lines, &String.contains?(&1, "\\n"))
    refute_tui_chrome(rendered)
  end

  test "escaped newline sequences are sanitized without splitting a retry log line" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{
             identifier: "MT-980",
             attempt: 1,
             due_in_ms: 1_500,
             error: "error with \\nnewline"
           })
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered =
      snapshot_data
      |> render_status(0.0)
      |> strip_ansi()

    retry_lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, "MT-980"))

    assert retry_lines == [
             ~S|level=warning source=retry entity=MT-980 message="error with newline" attempt="1" due_in="1.500s"|
           ]
  end

  test "unlimited credits rate limit renders in log message" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-777",
             state: "running",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "codex/event/token_count",
             last_codex_message: token_usage_message(90, 12, 102)
           })
         ],
         retrying: [],
         codex_totals: %{input_tokens: 90, output_tokens: 12, total_tokens: 102, seconds_running: 75},
         rate_limits: %{
           limit_id: "priority-tier",
           primary: %{remaining: 100, limit: 100, reset_in_seconds: 1},
           secondary: %{remaining: 500, limit: 500, reset_in_seconds: 1},
           credits: %{unlimited: true}
         }
       }}

    rendered =
      snapshot_data
      |> render_status(42.0)
      |> strip_ansi()

    assert rendered =~ ~S<source=codex entity=rate_limits message="priority-tier | primary 100/100 reset 1s | secondary 500/500 reset 1s | credits unlimited">
    assert rendered =~ ~S|source=codex entity=MT-777 message="thread token usage updated (in 90, out 12, total 102)"|
    refute_tui_chrome(rendered)
  end

  defp render_status(snapshot_data, tps) do
    StatusDashboard.format_snapshot_content_for_test(snapshot_data, tps, @terminal_columns)
  end

  defp idle_snapshot do
    {:ok,
     %{
       running: [],
       retrying: [],
       codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
       rate_limits: nil
     }}
  end

  defp strip_ansi(content), do: Regex.replace(~r/\e\[[0-9;]*m/, content, "")

  defp refute_tui_chrome(rendered) do
    refute rendered =~ "SYMPHONY STATUS"
    refute rendered =~ "╭"
    refute rendered =~ "├"
    refute rendered =~ "╰"
    refute rendered =~ "│"
    refute rendered =~ "─"
    refute rendered =~ "ID       STAGE"
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "MT-000",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 0,
        runtime_seconds: 0,
        turn_count: 1,
        last_codex_event: :notification,
        last_codex_message: turn_started_message()
      },
      overrides
    )
  end

  defp retry_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "MT-000",
        attempt: 1,
        due_in_ms: 1_000,
        error: "retry scheduled"
      },
      overrides
    )
  end

  defp turn_started_message do
    %{
      event: :notification,
      message: %{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => "turn-1"}}
      }
    }
  end

  defp turn_completed_message(status) do
    %{
      event: :notification,
      message: %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => status}}
      }
    }
  end

  defp exec_command_message(command) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end

  defp agent_message_delta(delta) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{"msg" => %{"payload" => %{"delta" => delta}}}
      }
    }
  end

  defp token_usage_message(input_tokens, output_tokens, total_tokens) do
    %{
      event: :notification,
      message: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => input_tokens,
              "outputTokens" => output_tokens,
              "totalTokens" => total_tokens
            }
          }
        }
      }
    }
  end
end

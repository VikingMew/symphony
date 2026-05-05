defmodule SymphonyElixir.StatusDashboardLogTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  test "offline status uses Logger instead of writing a terminal status line" do
    output =
      capture_io(fn ->
        log =
          capture_log(fn ->
            assert :ok = StatusDashboard.render_offline_status()
          end)

        assert log =~ "Symphony application offline"
        refute log =~ "level="
        refute log =~ "source="
      end)

    assert output == ""
  end

  test "status snapshot formatter is silent for idle and active states" do
    assert StatusDashboard.format_snapshot_content_for_test(idle_snapshot(), 0.0) == ""

    active_snapshot =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-101",
             state: "running",
             session_id: "thread-abcdef1234567890",
             codex_app_server_pid: "5252",
             codex_total_tokens: 89_200,
             runtime_seconds: 412,
             turn_count: 4,
             last_codex_event: "codex/event/task_started",
             last_codex_message: exec_command_message("mix test --cover")
           }
         ],
         retrying: [
           %{
             issue_id: "issue-1",
             identifier: "MT-450",
             attempt: 4,
             due_in_ms: 1_250,
             error: "rate limit exhausted"
           }
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    assert StatusDashboard.format_snapshot_content_for_test(active_snapshot, 0.0, 115) == ""
    assert StatusDashboard.format_snapshot_content_for_test(:error, 0.0) == ""
  end

  test "polling countdown-only changes are silent" do
    waiting_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
       }}

    checking_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
       }}

    assert StatusDashboard.format_snapshot_content_for_test(waiting_snapshot, 0.0) == ""
    assert StatusDashboard.format_snapshot_content_for_test(checking_snapshot, 0.0) == ""
  end

  test "status dashboard module does not contain the old terminal status format" do
    source =
      "lib/symphony_elixir/status_dashboard.ex"
      |> Path.expand(File.cwd!())
      |> File.read!()

    refute source =~ "IO.ANSI.home"
    refute source =~ "IO.ANSI.clear"
    refute source =~ "terminal_log_line"
    refute source =~ "level=#"
    refute source =~ "source=#"
    refute source =~ "entity=#"
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

  defp exec_command_message(command) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end
end

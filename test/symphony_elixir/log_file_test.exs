defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: false

  require Logger

  alias SymphonyElixir.{LogFile, LogFormatter}

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end

  test "formatter emits one JSON object with stable correlation fields" do
    line =
      LogFormatter.format(
        %{
          level: :error,
          msg: {:string, "tool failed"},
          meta: %{
            time: 1_799_000_000_000_000,
            event: "linear.tool_call.failed",
            issue_id: "issue-1",
            run_id: "run-1",
            tool_call_id: "call-1",
            operation: "linear_task_update",
            location: "dynamic_tool",
            expected_shape: "typed error envelope",
            error_code: "linear_transport_failed",
            retryable: true,
            mfa: {__MODULE__, :sample, 0},
            file: ~c"test/log_file_test.exs",
            line: 20
          }
        },
        %{}
      )
      |> IO.iodata_to_binary()

    assert String.ends_with?(line, "\n")
    refute String.contains?(String.trim_trailing(line), "\n")

    assert Jason.decode!(line) == %{
             "timestamp" => "2027-01-03T18:13:20.000000Z",
             "level" => "error",
             "event" => "linear.tool_call.failed",
             "message" => "tool failed",
             "issue_id" => "issue-1",
             "run_id" => "run-1",
             "tool_call_id" => "call-1",
             "operation" => "linear_task_update",
             "location" => "dynamic_tool",
             "expected_shape" => "typed error envelope",
             "error_code" => "linear_transport_failed",
             "retryable" => true,
             "source" => %{
               "module" => "SymphonyElixir.LogFileTest",
               "function" => "sample/0",
               "file" => "test/log_file_test.exs",
               "line" => 20
             }
           }
  end

  test "formatter preserves Unicode chardata in framework messages" do
    event = %{
      level: :info,
      msg: {:string, ["Sent 200 in ", ["15", [181, ?s]]]},
      meta: %{time: 0, mfa: {__MODULE__, :unicode_message, 0}}
    }

    assert [line, ?\n] = LogFormatter.format(event, %{})
    assert %{"message" => "Sent 200 in 15µs"} = Jason.decode!(line)
  end

  test "rotating file records are JSON Lines filterable without message matching" do
    root = Path.join(System.tmp_dir!(), "symphony-json-log-#{System.unique_integer([:positive])}")
    path = Path.join(root, "symphony.log")
    previous = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :log_file, previous),
        else: Application.delete_env(:symphony_elixir, :log_file)

      LogFile.configure()
      File.rm_rf!(root)
    end)

    Application.put_env(:symphony_elixir, :log_file, path)
    assert :ok = LogFile.configure()

    Logger.info("human wording is irrelevant",
      event: "linear.tool_call.completed",
      issue_id: "issue-json",
      run_id: "run-json",
      tool_call_id: "call-json"
    )

    :ok = :logger_disk_log_h.filesync(:symphony_disk_log)

    records =
      path
      |> then(&Path.wildcard(&1 <> "*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "{"))
        |> Enum.map(&Jason.decode!/1)
      end)

    assert Enum.any?(records, fn record ->
             record["event"] == "linear.tool_call.completed" and
               record["issue_id"] == "issue-json" and
               record["run_id"] == "run-json" and
               record["tool_call_id"] == "call-json"
           end)
  end
end

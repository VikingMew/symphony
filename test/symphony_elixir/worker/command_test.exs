defmodule SymphonyElixir.Worker.CommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Command
  alias SymphonyElixir.WorkerResult

  test "records the Codex session marker and duration" do
    result =
      Command.run(
        %{command: "printf 'SYMPHONY_CODEX_SESSION_ID=session-123\\n'", timeout_seconds: 5},
        File.cwd!()
      )

    assert result.status == :passed
    assert result.session_id == "session-123"
    assert is_integer(result.duration_ms)
  end

  test "classifies missing commands as toolchain unavailable" do
    result = Command.run(%{command: "missing-symphony-tool", timeout_seconds: 5}, File.cwd!())
    assert result.status == :toolchain_unavailable
    assert result.exit_code == 127
  end

  test "does not hang on commands that read stdin (regression: codex exec waits on stdin)" do
    # `cat` blocks reading stdin; with stdin redirected to /dev/null it must exit immediately.
    result = Command.run(%{command: "cat", timeout_seconds: 3}, File.cwd!())
    assert result.status == :passed
    assert result.exit_code == 0
  end

  test "streams bounded output chunks while retaining the final bounded result" do
    owner = self()

    result =
      Command.run(
        %{command: "printf 'first\\n'; printf 'second\\n' >&2", timeout_seconds: 5},
        File.cwd!(),
        &send(owner, {:output, &1})
      )

    assert_receive {:output, chunk}
    assert chunk =~ "first"
    assert result.status == :passed
    assert result.detail =~ "first"
    assert result.detail =~ "second"
  end

  test "returns actual duration and recent output on timeout" do
    result =
      Command.run(
        %{command: "printf 'waiting\\n'; sleep 5", timeout_seconds: 1},
        File.cwd!()
      )

    assert result.status == :timed_out
    assert result.duration_ms >= 1_000
    assert result.detail =~ "waiting"
  end

  test "includes the truncation marker within the shared source output budget" do
    limit = WorkerResult.limits().max_source_output
    result = Command.run(%{command: "printf '%05000d' 0", timeout_seconds: 5}, File.cwd!())

    assert result.status == :passed
    assert byte_size(result.detail) == limit
    assert result.detail =~ "... (truncated)"
  end
end

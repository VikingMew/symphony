defmodule SymphonyElixir.Worker.CommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Command

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
end

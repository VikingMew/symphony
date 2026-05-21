defmodule SymphonyElixir.CodexStartupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Startup

  test "launch command runs pre-start commands before execing codex" do
    command =
      Startup.launch_command(%{
        pre_start_commands: [" source ~/.nvs/nvs.sh ", "", "nvs use 22 >/dev/null"],
        command: "codex app-server"
      })

    assert command =~ "__symphony_codex_pre_start_index=1"
    assert command =~ "source ~/.nvs/nvs.sh"
    assert command =~ "__symphony_codex_pre_start_index=2"
    assert command =~ "nvs use 22 >/dev/null"
    assert String.ends_with?(command, "exec codex app-server")
  end

  test "shell control commands are not prefixed with exec" do
    assert Startup.launch_command(%{command: "nvs use 22 && codex app-server"}) == "nvs use 22 && codex app-server"
  end

  test "startup failure classifies approval policy response errors" do
    {:codex_startup_failed, details} =
      Startup.failure(
        {:response_error, %{"message" => "Invalid request: unknown variant `reject`"}},
        :thread_start,
        %{command: "codex app-server", workspace: "/tmp/ws"},
        "",
        5000
      )

    assert details.reason == :response_error
    assert details.response_error["message"] =~ "unknown variant"
    assert details.hint =~ "Settings / Workflow / Codex / Approval policy"
  end

  test "startup output is bounded and redacted" do
    output = Startup.append_output("", String.duplicate("a", 5_000))
    assert output =~ "... (truncated)"

    assert Startup.sanitize_output("token=ghp_secret") =~ "token=[REDACTED]"
  end
end

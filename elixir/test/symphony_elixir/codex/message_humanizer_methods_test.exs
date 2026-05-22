defmodule SymphonyElixir.Codex.MessageHumanizer.MethodsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageHumanizer.Methods

  test "humanizes JSON-RPC method payloads independently" do
    payload = %{
      "params" => %{
        "turn" => %{"status" => "completed"},
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }
    }

    assert Methods.humanize("turn/completed", payload) == "turn completed (completed) (in 10, out 5)"
  end

  test "delegates codex wrapper method payloads to wrapper formatter" do
    payload = %{"params" => %{"msg" => %{"command" => "git status --short"}}}

    assert Methods.humanize("codex/event/exec_command_begin", payload) == "git status --short"
  end
end

defmodule SymphonyElixir.RedactionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Redaction

  test "redacts credential-shaped output and bounds logs" do
    output = "Authorization: Bearer abc token=secret api_key=key " <> String.duplicate("x", 20)

    assert Redaction.credentials(output) =~ "Authorization: [REDACTED]"
    assert Redaction.credentials(output) =~ "token=[REDACTED]"
    assert Redaction.credentials(output) =~ "api_key=[REDACTED]"
    assert Redaction.credentials(~s({:token, "secret-token-value"})) =~ ~s({:token, "[REDACTED]"})
    assert Redaction.bounded(output, 24) =~ "... (truncated)"
  end

  test "redacts environment values, URI userinfo, and control bytes" do
    previous = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "secret-value")

    on_exit(fn ->
      if previous, do: System.put_env("LINEAR_API_KEY", previous), else: System.delete_env("LINEAR_API_KEY")
    end)

    assert Redaction.sensitive_env_values("value=secret-value", ["LINEAR_API_KEY"]) == "value=[REDACTED LINEAR_API_KEY]"
    assert Redaction.uri_userinfo("https://user:pass@example.test/path") == "https://[REDACTED]@example.test/path"
    assert Redaction.ansi_and_control("\e[31mred\e[0m\n") == "red"
  end
end

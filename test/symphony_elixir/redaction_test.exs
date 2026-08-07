defmodule SymphonyElixir.RedactionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.{LinearToolAudit, Update}
  alias SymphonyElixir.EventPresenter
  alias SymphonyElixir.Redaction
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  test "redacts credential-shaped output and bounds logs" do
    output = "Authorization: Bearer abc token=secret api_key=key " <> String.duplicate("x", 20)

    assert Redaction.credentials(output) =~ "Authorization: [REDACTED]"
    assert Redaction.credentials(output) =~ "token=[REDACTED]"
    assert Redaction.credentials(output) =~ "api_key=[REDACTED]"
    assert Redaction.credentials(~s({:token, "secret-token-value"})) =~ ~s({:token, "[REDACTED]"})
    assert Redaction.bounded(output, 24) =~ "... (truncated)"
  end

  test "recursively sanitizes payloads with one bounded policy" do
    payload = %{
      "message" => "request failed: Authorization: Bearer embedded-secret",
      "nested" => [%{"api_token" => "key-secret", "at" => ~U[2026-08-08 00:00:00Z]}],
      "long" => String.duplicate("x", 600),
      "count" => 3
    }

    sanitized = Redaction.payload(payload, 500)

    assert sanitized["message"] == "request failed: Authorization: [REDACTED]"
    assert sanitized["nested"] == [%{"api_token" => "[REDACTED]", "at" => "2026-08-08T00:00:00Z"}]
    assert sanitized["long"] == String.duplicate("x", 500) <> "... (truncated)"
    assert sanitized["count"] == 3
  end

  test "all observability entry points apply the same recursive sanitizer" do
    payloads = [
      %{
        "message" => "request failed: Authorization: Bearer ordinary-secret",
        "nested" => [%{"api_token" => "key-secret", "at" => ~U[2026-08-08 00:00:00Z]}],
        "long" => String.duplicate("x", 600)
      },
      %{
        message: "response token=ordinary-secret",
        details: [%{cookie: "session-secret"}, %{value: "api_key=ordinary-secret"}],
        occurred_at: ~U[2026-08-08 01:02:03Z]
      }
    ]

    Enum.each(payloads, fn payload ->
      FakePersistence.reset!()
      expected = Redaction.payload(payload, 500)

      event_payload = EventPresenter.row(%{event_type: "run.started", payload: payload}).raw_payload
      debug_payload = Update.rate_limit_debug_payload(%{payload: payload}).payload
      persisted_payload = Update.event_payload(%{event: :notification, payload: payload}).debug.payload

      assert :ok = LinearToolAudit.record("linear_task_update", payload, %{"success" => true, "output" => "{}"}, [])
      [audit_event] = FakePersistence.list_events(event_type: "linear.tool_call")

      sanitized_payloads = [event_payload, audit_event.payload.arguments, debug_payload, persisted_payload]

      assert sanitized_payloads == List.duplicate(expected, 4)
      assert ObservabilityPresenter.safe_event_payload(payload) == inspect_payload(expected)
      refute inspect(expected) =~ "ordinary-secret"
      refute inspect(expected) =~ "key-secret"
      refute inspect(expected) =~ "session-secret"
    end)
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

  defp inspect_payload(payload) do
    inspected = inspect(payload, pretty: true, limit: 20)

    if byte_size(inspected) > 2_000,
      do: binary_part(inspected, 0, 2_000) <> "\n... truncated",
      else: inspected
  end
end

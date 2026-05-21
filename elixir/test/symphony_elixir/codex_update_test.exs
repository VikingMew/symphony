defmodule SymphonyElixir.CodexUpdateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Update

  test "integrate coalesces streaming agent message fragments with the same key" do
    base = %{session_id: "thread-1", session_history: [], session_history_total_count: 0}

    update_a = streaming_update("thread-1", "item-1", "hello")
    update_b = streaming_update("thread-1", "item-1", "world")

    {entry, _delta} = Update.integrate(base, update_a)
    {entry, _delta} = Update.integrate(entry, update_b)

    assert entry.session_history_total_count == 2
    assert [event] = entry.session_history
    assert event.detail == "agent message streaming: hello world (2 fragments)"
  end

  test "integrate keeps streaming fragments separate when keys differ" do
    base = %{session_id: "thread-1", session_history: [], session_history_total_count: 0}

    {entry, _delta} = Update.integrate(base, streaming_update("thread-1", "item-1", "hello"))
    {entry, _delta} = Update.integrate(entry, streaming_update("thread-1", "item-2", "world"))

    assert entry.session_history_total_count == 2
    assert length(entry.session_history) == 2
  end

  test "token delta prefers absolute token usage paths" do
    update = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        "params" => %{
          "msg" => %{
            "payload" => %{
              "info" => %{
                "total_token_usage" => %{
                  "input_tokens" => 30,
                  "output_tokens" => 12,
                  "total_tokens" => 42
                }
              }
            }
          }
        }
      }
    }

    delta = Update.token_delta(%{codex_last_reported_input_tokens: 10}, update)
    assert delta.input_tokens == 20
    assert delta.output_tokens == 12
    assert delta.total_tokens == 42
  end

  test "rate limits are found in nested payloads" do
    rate_limits = %{"limit_id" => "primary", "primary" => %{"remaining" => 1}}
    assert Update.rate_limits(%{payload: %{"nested" => %{"rate_limits" => rate_limits}}}) == rate_limits
  end

  test "event payload redacts and truncates sensitive debug content" do
    payload = Update.event_payload(%{event: :notification, payload: %{"api_key" => "secret", "message" => String.duplicate("a", 1_200)}})

    assert payload.debug.payload["api_key"] == "[REDACTED]"
    assert payload.debug.payload["message"] =~ "... (truncated)"
  end

  defp streaming_update(session_id, item_id, delta) do
    %{
      event: :notification,
      session_id: session_id,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"id" => item_id, "delta" => delta}
      }
    }
  end
end

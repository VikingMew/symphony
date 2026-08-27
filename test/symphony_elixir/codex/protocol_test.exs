defmodule SymphonyElixir.Codex.ProtocolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageHumanizer.Methods
  alias SymphonyElixir.Codex.Protocol
  alias SymphonyElixir.RunHistory

  describe "event normalization" do
    test "one normalized event shape drives history and humanizer formatting" do
      cases = [
        %{
          payload: %{
            method: "turn/completed",
            params: %{
              threadId: "thread-1",
              turn: %{id: "turn-1", status: "completed", durationMs: 125},
              usage: %{inputTokens: 10, outputTokens: 5, totalTokens: 15}
            }
          },
          fields: %{method: "turn/completed", thread_id: "thread-1", turn_id: "turn-1", input_tokens: 10, output_tokens: 5, total_tokens: 15},
          humanized: "turn completed (completed) (in 10, out 5, total 15)",
          history: "turn completed (completed) in 125ms"
        },
        %{
          payload: %{
            "method" => "item/completed",
            :params => %{
              "item" => %{
                "type" => "agentMessage",
                "status" => "completed",
                id: "item-1",
                phase: "final_answer",
                text: "Done"
              }
            }
          },
          fields: %{method: "item/completed", item_id: "item-1", item_type: "agentMessage", item_status: "completed", item_phase: "final_answer"},
          humanized: "item completed: agent message (item-1, completed)",
          history: "agent final answer: Done"
        },
        %{
          payload: %{
            :method => "thread/tokenUsage/updated",
            "params" => %{
              tokenUsage: %{
                "total" => %{"outputTokens" => 3, input_tokens: 8, totalTokens: 11}
              }
            }
          },
          fields: %{method: "thread/tokenUsage/updated", input_tokens: 8, output_tokens: 3, total_tokens: 11},
          humanized: "thread token usage updated (in 8, out 3, total 11)",
          history: "thread token usage updated (total 11, in 8, out 3)"
        },
        %{
          payload: %{
            "method" => "account/rateLimits/updated",
            params: %{
              rateLimits: %{
                primary: %{usedPercent: 42, windowDurationMins: 300}
              }
            }
          },
          fields: %{method: "account/rateLimits/updated"},
          humanized: "rate limits updated: primary 42% / 300m",
          history: "rate limits updated: primary 42% / 300m"
        }
      ]

      Enum.each(cases, fn test_case ->
        event = Protocol.normalize_event(test_case.payload)

        assert Map.take(Map.from_struct(event), Map.keys(test_case.fields)) == test_case.fields
        assert Methods.humanize(event) == test_case.humanized

        history_event =
          RunHistory.from_event(%{
            event_type: "codex.update",
            payload: %{"event" => "notification", "message" => event}
          })

        assert history_event.detail == test_case.history
        assert history_event.metadata["method"] == event.method
        assert history_event.metadata["item_id"] == event.item_id
        assert history_event.metadata["thread_id"] == event.thread_id
        assert history_event.metadata["turn_id"] == event.turn_id
      end)
    end

    test "normalizes atom method names and nested per-level key variants" do
      event =
        Protocol.normalize_event(%{
          :method => :turn_completed,
          "params" => %{
            turn: %{"id" => "turn-2", status: "completed"},
            token_usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}
          }
        })

      assert event.method == "turn/completed"
      assert event.turn_id == "turn-2"
      assert %{input_tokens: 2, output_tokens: 1, total_tokens: 3} = event
    end
  end

  describe "message framing" do
    test "encodes JSON-RPC messages as newline-delimited JSON" do
      assert IO.iodata_to_binary(Protocol.encode_message(%{"id" => 1, "method" => "initialize"})) ==
               ~s({"id":1,"method":"initialize"}\n)
    end

    test "buffers partial lines until the caller receives an eol chunk" do
      pending = Protocol.complete_line("", ~s({"id":3,))

      assert Protocol.complete_line(pending, ~s("result":{"turn":{"id":"turn-1"}}})) ==
               ~s({"id":3,"result":{"turn":{"id":"turn-1"}}})
    end
  end

  describe "response decoding" do
    test "matches successful request responses by id" do
      assert Protocol.decode_response_line(~s({"id":2,"result":{"thread":{"id":"thread-1"}}}), 2) ==
               {:response_result, %{"thread" => %{"id" => "thread-1"}}}
    end

    test "matches error responses by id" do
      error = %{"code" => -32_600, "message" => "invalid request"}

      assert Protocol.decode_response_line(Jason.encode!(%{"id" => 2, "error" => error}), 2) ==
               {:response_error, error}
    end

    test "ignores responses for other request ids" do
      assert Protocol.decode_response_line(~s({"id":99,"result":{}}), 2) ==
               {:other, %{"id" => 99, "result" => %{}}}
    end

    test "classifies malformed response lines" do
      assert Protocol.decode_response_line(~s({"id":2,"result":), 2) ==
               {:malformed, ~s({"id":2,"result":)}
    end
  end

  describe "turn stream decoding" do
    test "classifies terminal turn notifications" do
      assert Protocol.decode_turn_stream_line(~s({"method":"turn/completed","params":{"status":"ok"}})) ==
               {:turn_completed, %{"method" => "turn/completed", "params" => %{"status" => "ok"}}, ~s({"method":"turn/completed","params":{"status":"ok"}})}

      assert Protocol.decode_turn_stream_line(~s({"method":"turn/failed","params":{"reason":"boom"}})) ==
               {:turn_failed, %{"method" => "turn/failed", "params" => %{"reason" => "boom"}}, %{"reason" => "boom"}, ~s({"method":"turn/failed","params":{"reason":"boom"}})}
    end

    test "classifies notifications and non-protocol stream lines" do
      assert Protocol.decode_turn_stream_line(~s({"method":"item/updated","params":{"id":"1"}})) ==
               {:notification, "item/updated", %{"method" => "item/updated", "params" => %{"id" => "1"}}, ~s({"method":"item/updated","params":{"id":"1"}})}

      assert Protocol.decode_turn_stream_line("warning: stderr noise") ==
               {:stream_line, "warning: stderr noise"}
    end

    test "surfaces JSON-like malformed lines as protocol candidates" do
      assert Protocol.decode_turn_stream_line(~s({"method":"turn/completed")) ==
               {:malformed_candidate, ~s({"method":"turn/completed")}
    end
  end

  describe "stream log classification" do
    test "keeps warning-looking output at warning level" do
      assert Protocol.stream_log_entry("fatal: cannot fetch") == {:warning, "fatal: cannot fetch"}
      assert Protocol.stream_log_entry("progress line") == {:debug, "progress line"}
      assert Protocol.stream_log_entry("   ") == nil
    end
  end
end

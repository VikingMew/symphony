defmodule SymphonyElixir.Codex.ProtocolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Protocol

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
      error = %{"code" => -32600, "message" => "invalid request"}

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

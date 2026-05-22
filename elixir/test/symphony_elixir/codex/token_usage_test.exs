defmodule SymphonyElixir.Codex.TokenUsageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.TokenUsage

  test "extracts total token usage from app-server tokenUsage payload" do
    payload = %{
      "params" => %{
        "tokenUsage" => %{
          "total" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
        }
      }
    }

    assert TokenUsage.absolute_usage(payload) == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
  end

  test "extracts wrapper total_token_usage payloads" do
    payload = %{
      "params" => %{
        "msg" => %{
          "payload" => %{
            "info" => %{
              "total_token_usage" => %{"prompt_tokens" => "7", "completion_tokens" => 3, "total_tokens" => 10}
            }
          }
        }
      }
    }

    assert TokenUsage.absolute_usage(payload) == %{input_tokens: 7, output_tokens: 3, total_tokens: 10}
  end

  test "preserves existing simple tokens fixture shape" do
    payload = %{"tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}}

    assert TokenUsage.absolute_usage(payload) == %{input_tokens: 4, output_tokens: 8, total_tokens: 12}
  end
end

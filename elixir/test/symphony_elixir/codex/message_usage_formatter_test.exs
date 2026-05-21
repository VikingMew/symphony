defmodule SymphonyElixir.Codex.MessageUsageFormatterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageUsageFormatter

  test "formats usage counts across naming variants" do
    assert MessageUsageFormatter.format_usage_counts(%{"inputTokens" => 1_000, "completion_tokens" => 20, "total" => "1020"}) ==
             "in 1,000, out 20, total 1,020"
  end

  test "formats rate limit summaries" do
    assert MessageUsageFormatter.format_rate_limits_summary(%{"primary" => %{"usedPercent" => 42, "windowDurationMins" => 300}}) ==
             "primary 42% / 300m"

    assert MessageUsageFormatter.format_rate_limits_summary(nil) == "n/a"
  end
end

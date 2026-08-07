defmodule SymphonyElixir.MixedKeyAccessGovernanceTest do
  use ExUnit.Case, async: true

  @allowed_manual_boundaries [
    "lib/symphony_elixir/analytics.ex",
    "lib/symphony_elixir/codex/message_humanizer.ex",
    "lib/symphony_elixir/codex/startup.ex",
    "lib/symphony_elixir/codex/update.ex",
    "lib/symphony_elixir/event_presenter.ex",
    "lib/symphony_elixir/linear/diagnostics.ex",
    "lib/symphony_elixir/linear/health.ex",
    "lib/symphony_elixir/merge_executor.ex",
    "lib/symphony_elixir/persistence/worker_queue.ex",
    "lib/symphony_elixir/persistence/workflow_store.ex",
    "lib/symphony_elixir/profile_prompt_summary.ex",
    "lib/symphony_elixir/run_history.ex",
    "lib/symphony_elixir_web/dashboard_presenter.ex",
    "lib/symphony_elixir_web/linear_status_signal.ex",
    "lib/symphony_elixir_web/live/admin_live.ex",
    "lib/symphony_elixir_web/presenter.ex",
    "lib/symphony_elixir_web/rate_limit_status.ex"
  ]

  test "manual mixed atom/string key fallbacks stay in audited boundary modules" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&manual_mixed_key_fallbacks/1)
      |> Enum.reject(fn {path, _line} -> path in @allowed_manual_boundaries end)

    assert offenders == []
  end

  defp manual_mixed_key_fallbacks(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} ->
      (String.contains?(line, "Map.get(") and String.contains?(line, "||") and
         Regex.match?(~r/Map\.get\([^)]*,\s*:/, line) and Regex.match?(~r/Map\.get\([^)]*,\s*"/, line)) or
        String.contains?(line, "map_get(")
    end)
    |> Enum.map(fn {_line, line_no} -> {path, line_no} end)
  end
end

defmodule SymphonyElixir.RunSummary do
  @moduledoc """
  Deterministic summary derivation for a persisted run history.

  `RunHistory` owns timeline row normalization. This module owns the compact
  run-detail summary shown above the raw session history.
  """

  alias SymphonyElixir.Payload

  @type t :: %{
          outcome: String.t(),
          final_message: String.t() | nil,
          last_codex_detail: String.t() | nil,
          actions: [String.t()],
          tools: [String.t()],
          commands: [String.t()],
          linear_updates: [String.t()],
          highlights: [String.t()],
          blockers: [String.t()],
          sessions: [String.t()],
          evidence_quality: :complete | :partial | :low_signal
        }

  @spec summarize(map() | nil, [map()]) :: t()
  def summarize(run, history) when is_list(history) do
    useful = Enum.reject(history, &Map.get(&1, :low_signal, false))

    %{
      outcome: run_outcome(run),
      final_message: final_agent_message(useful),
      last_codex_detail: last_codex_detail(useful),
      actions: actions(useful),
      tools: tool_summaries(useful),
      commands: command_summaries(useful),
      linear_updates: linear_updates(useful),
      highlights: useful |> Enum.filter(&highlight?/1) |> Enum.map(& &1.detail) |> Enum.uniq() |> Enum.take(5),
      blockers: blockers(run, useful),
      sessions: session_ids(history),
      evidence_quality: evidence_quality(useful)
    }
  end

  defp run_outcome(nil), do: "n/a"
  defp run_outcome(run), do: "#{Map.get(run, :status, "unknown")} attempt #{Map.get(run, :attempt, "n/a")}"

  defp last_codex_detail(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn row ->
      if row.source == :agent and is_binary(row.detail) and row.detail not in ["", "codex.update"], do: row.detail
    end)
  end

  defp final_agent_message(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn row ->
      detail = to_string(row.detail || "")

      cond do
        String.starts_with?(detail, "agent final answer:") ->
          detail |> String.replace_prefix("agent final answer:", "") |> String.trim()

        String.starts_with?(detail, "agent message completed:") ->
          detail |> String.replace_prefix("agent message completed:", "") |> String.trim()

        String.starts_with?(detail, "agent message streaming:") ->
          detail |> String.replace_prefix("agent message streaming:", "") |> String.trim()

        String.starts_with?(detail, "agent message content streaming:") ->
          detail |> String.replace_prefix("agent message content streaming:", "") |> String.trim()

        true ->
          nil
      end
    end)
  end

  defp actions(history) do
    history
    |> Enum.map(&action_summary/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp action_summary(%{detail: detail}) when is_binary(detail) do
    cond do
      String.contains?(detail, "dynamic tool call requested") -> detail
      String.contains?(detail, "dynamic tool call completed") -> detail
      String.contains?(detail, "command completed") -> detail
      String.contains?(detail, "turn completed") -> detail
      String.contains?(detail, "session started") -> detail
      true -> nil
    end
  end

  defp action_summary(_row), do: nil

  defp tool_summaries(history) do
    history
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.map(fn {tool, count} -> "#{tool} x#{count}" end)
    |> Enum.sort()
    |> Enum.take(6)
  end

  defp tool_name(%{detail: detail}) when is_binary(detail) do
    case Regex.run(~r/dynamic tool call (?:requested|completed|failed|rejected) \(([^)]+)\)/, detail) do
      [_match, tool] -> tool
      _ -> nil
    end
  end

  defp tool_name(_row), do: nil

  defp command_summaries(history) do
    history
    |> Enum.map(&command_summary/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp command_summary(%{label: label, detail: detail}) when is_binary(detail) do
    cond do
      String.contains?(to_string(label), "Command") -> detail
      String.starts_with?(detail, "command completed") -> detail
      Regex.match?(~r/^(git|mix|mise|npm|pnpm|yarn|cargo|go|python|ruby|node)\b/, detail) -> detail
      true -> nil
    end
  end

  defp command_summary(_row), do: nil

  defp linear_updates(history) do
    history
    |> Enum.filter(&(&1.source == :linear or String.starts_with?(to_string(&1.event), "linear.")))
    |> Enum.map(& &1.detail)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp evidence_quality(history) do
    cond do
      final_agent_message(history) -> :complete
      Enum.any?(history, &highlight?/1) -> :partial
      true -> :low_signal
    end
  end

  defp highlight?(row) do
    detail = to_string(row.detail || "")
    String.contains?(detail, ["tool", "command", "session completed", "turn completed", "agent message"])
  end

  defp blockers(run, history) do
    run_failure =
      case run && Map.get(run, :failure_reason) do
        reason when is_binary(reason) and reason != "" -> [reason]
        _ -> []
      end

    history_failures =
      history
      |> Enum.filter(&(&1.severity in [:warning, :error]))
      |> Enum.map(& &1.detail)
      |> Enum.reject(&blank?/1)

    (run_failure ++ history_failures)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp session_ids(history) do
    history
    |> Enum.map(fn row -> Payload.get_any(row.metadata, ["session_id", :session_id]) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end

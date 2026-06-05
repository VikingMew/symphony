defmodule SymphonyElixirWeb.RateLimitStatus do
  @moduledoc """
  Dashboard-facing rate-limit observability projection.
  """

  alias SymphonyElixir.Codex.MessageHumanizer

  @spec from_snapshot(map()) :: map()
  def from_snapshot(snapshot) when is_map(snapshot) do
    rate_limits = Map.get(snapshot, :rate_limits)
    observation = Map.get(snapshot, :rate_limit_observation)
    gate = Map.get(snapshot, :rate_limit_gate)

    status =
      cond do
        gate_blocked?(gate) -> :blocked
        is_map(rate_limits) -> :available
        rate_limit_observed?(observation) -> :unrecognized
        true -> :not_received
      end

    %{
      status: status,
      snapshot: rate_limits,
      gate: gate,
      note: note(status, gate),
      last_codex_event: last_codex_event(snapshot),
      last_codex_timestamp: last_codex_timestamp(snapshot),
      last_codex_message: last_codex_message(snapshot),
      token_totals: Map.get(snapshot, :codex_totals, %{}),
      active_sessions: snapshot |> Map.get(:running, []) |> length(),
      observation: observation,
      debug_payload: debug_payload(status, observation)
    }
  end

  def from_snapshot(_snapshot), do: from_snapshot(%{})

  defp note(:blocked, gate), do: "Dispatch paused by Codex rate-limit headroom: #{gate_note(gate)}"
  defp note(:available, _gate), do: "Upstream Codex rate-limit snapshot received."
  defp note(:unrecognized, _gate), do: "A Codex rate-limit update was received, but Symphony did not recognize its payload shape."
  defp note(:not_received, _gate), do: "No upstream rate-limit snapshot received yet; enforcement is unavailable and dispatch is allowed."

  defp gate_blocked?(%{status: :blocked}), do: true
  defp gate_blocked?(%{"status" => "blocked"}), do: true
  defp gate_blocked?(_gate), do: false

  defp gate_note(gate) when is_map(gate) do
    window = Map.get(gate, :window) || Map.get(gate, "window") || "unknown window"
    remaining = Map.get(gate, :remaining_percent) || Map.get(gate, "remaining_percent") || "n/a"
    threshold = Map.get(gate, :threshold_percent) || Map.get(gate, "threshold_percent") || "n/a"
    resume_after = Map.get(gate, :resume_after) || Map.get(gate, "resume_after") || "n/a"
    "#{window} remaining #{remaining}% below #{threshold}%; resume after #{resume_after}"
  end

  defp gate_note(_gate), do: "details unavailable"

  defp rate_limit_observed?(%{status: :unrecognized}), do: true
  defp rate_limit_observed?(%{"status" => "unrecognized"}), do: true
  defp rate_limit_observed?(_observation), do: false

  defp debug_payload(:unrecognized, observation) when is_map(observation) do
    Map.get(observation, :debug_payload) || Map.get(observation, "debug_payload")
  end

  defp debug_payload(_status, _observation), do: nil

  defp last_codex_event(snapshot) do
    snapshot
    |> Map.get(:running, [])
    |> Enum.find_value(&Map.get(&1, :last_codex_event))
  end

  defp last_codex_timestamp(snapshot) do
    snapshot
    |> Map.get(:running, [])
    |> Enum.find_value(&Map.get(&1, :last_codex_timestamp))
  end

  defp last_codex_message(snapshot) do
    snapshot
    |> Map.get(:running, [])
    |> Enum.find_value(fn entry ->
      message = Map.get(entry, :last_codex_message)
      if is_nil(message), do: nil, else: MessageHumanizer.humanize_codex_message(message)
    end)
  end
end

defmodule SymphonyElixirWeb.RateLimitStatus do
  @moduledoc """
  Dashboard-facing rate-limit observability projection.
  """

  alias SymphonyElixir.StatusDashboard

  @spec from_snapshot(map()) :: map()
  def from_snapshot(snapshot) when is_map(snapshot) do
    rate_limits = Map.get(snapshot, :rate_limits)
    observation = Map.get(snapshot, :rate_limit_observation)

    status =
      cond do
        is_map(rate_limits) -> :available
        rate_limit_observed?(observation) -> :unrecognized
        true -> :not_received
      end

    %{
      status: status,
      snapshot: rate_limits,
      note: note(status),
      last_codex_event: last_codex_event(snapshot),
      last_codex_timestamp: last_codex_timestamp(snapshot),
      last_codex_message: last_codex_message(snapshot),
      token_totals: Map.get(snapshot, :codex_totals, %{}),
      active_sessions: snapshot |> Map.get(:running, []) |> length(),
      observation: observation
    }
  end

  def from_snapshot(_snapshot), do: from_snapshot(%{})

  defp note(:available), do: "Upstream Codex rate-limit snapshot received."
  defp note(:unrecognized), do: "A Codex rate-limit update was received, but Symphony did not recognize its payload shape."
  defp note(:not_received), do: "No upstream rate-limit snapshot received yet."

  defp rate_limit_observed?(%{status: :unrecognized}), do: true
  defp rate_limit_observed?(%{"status" => "unrecognized"}), do: true
  defp rate_limit_observed?(_observation), do: false

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
      if is_nil(message), do: nil, else: StatusDashboard.humanize_codex_message(message)
    end)
  end
end

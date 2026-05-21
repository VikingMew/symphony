defmodule SymphonyElixirWeb.LinearStatusSignal do
  @moduledoc """
  Compact Linear diagnostics signal for the dashboard.
  """

  alias SymphonyElixir.Linear.Health

  @spec unknown() :: map()
  def unknown do
    Health.unknown()
    |> from_health()
  end

  @spec from_diagnostics(map() | nil) :: map()
  def from_diagnostics(diagnostics), do: diagnostics |> Health.from_diagnostics() |> from_health()

  @spec from_health(map() | nil) :: map()
  def from_health(nil), do: unknown()

  def from_health(%{} = health) do
    status = Map.get(health, :display_status, Map.get(health, :status, :unknown))

    %{
      status: status,
      label: Map.get(health, :label, "Linear #{status}"),
      badge_class: badge_class(status),
      detail: Map.get(health, :display_detail) || Map.get(health, :detail) || "Open Linear diagnostics for details.",
      project_slug: Map.get(health, :project_slug) || "n/a",
      ran_at: Map.get(health, :observed_at),
      candidate_count: Map.get(health, :candidate_count),
      href: "/diagnostics/linear"
    }
  end

  defp badge_class(:ok), do: "status-badge status-success"
  defp badge_class(:warning), do: "status-badge status-warning"
  defp badge_class(:stale), do: "status-badge status-warning"
  defp badge_class(:error), do: "status-badge status-danger"
  defp badge_class(_status), do: "status-badge status-info"
end

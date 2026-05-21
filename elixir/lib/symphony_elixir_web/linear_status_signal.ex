defmodule SymphonyElixirWeb.LinearStatusSignal do
  @moduledoc """
  Compact Linear diagnostics signal for the dashboard.
  """

  alias SymphonyElixir.PersistenceProvider

  @spec unknown() :: map()
  def unknown do
    %{
      status: :unknown,
      label: "Linear unknown",
      badge_class: "status-badge status-info",
      detail: "Diagnostics have not been run from this dashboard snapshot.",
      project_slug: default_project_slug(),
      ran_at: nil,
      candidate_count: nil,
      href: "/diagnostics/linear"
    }
  end

  @spec from_diagnostics(map() | nil) :: map()
  def from_diagnostics(nil), do: unknown()

  def from_diagnostics(%{} = diagnostics) do
    probes = Map.get(diagnostics, :probes, %{})
    statuses = probes |> Map.values() |> Enum.map(&Map.get(&1, :status))
    primary = primary_probe(probes)
    status = status_from_probe_statuses(statuses)

    %{
      status: status,
      label: "Linear #{status}",
      badge_class: badge_class(status),
      detail: primary_detail(primary, status),
      project_slug: get_in(diagnostics, [:config, :project_slug]) || default_project_slug(),
      ran_at: Map.get(diagnostics, :ran_at),
      candidate_count: diagnostics |> Map.get(:issues, []) |> length(),
      href: "/diagnostics/linear"
    }
  end

  defp status_from_probe_statuses(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == :error)) -> :error
      Enum.any?(statuses, &(&1 == :warning)) -> :warning
      statuses != [] and Enum.all?(statuses, &(&1 in [:ok, :skipped])) -> :ok
      true -> :unknown
    end
  end

  defp primary_probe(probes) do
    Enum.find_value([:api, :project, :states, :candidates, :teams], fn key ->
      probe = Map.get(probes, key)
      if is_map(probe) and Map.get(probe, :status) in [:error, :warning], do: {key, probe}
    end)
  end

  defp primary_detail(nil, :ok), do: "Latest diagnostics did not report blocking Linear issues."
  defp primary_detail(nil, :unknown), do: "Open Linear diagnostics to run connectivity and state checks."
  defp primary_detail(nil, _status), do: "Open Linear diagnostics for details."
  defp primary_detail({key, probe}, _status), do: "#{human_key(key)}: #{Map.get(probe, :detail) || Map.get(probe, :title) || "check failed"}"

  defp human_key(:api), do: "API"
  defp human_key(:project), do: "Project"
  defp human_key(:states), do: "Workflow states"
  defp human_key(:candidates), do: "Candidate issues"
  defp human_key(:teams), do: "Teams"

  defp badge_class(:ok), do: "status-badge status-success"
  defp badge_class(:warning), do: "status-badge status-warning"
  defp badge_class(:error), do: "status-badge status-danger"
  defp badge_class(_status), do: "status-badge status-info"

  defp default_project_slug do
    case PersistenceProvider.module().default_project() do
      {:ok, project} -> Map.get(project, :linear_project_slug) || Map.get(project, "linear_project_slug") || "n/a"
      _error -> "n/a"
    end
  rescue
    _exception -> "n/a"
  catch
    _kind, _reason -> "n/a"
  end
end

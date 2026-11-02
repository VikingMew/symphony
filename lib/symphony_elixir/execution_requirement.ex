defmodule SymphonyElixir.ExecutionRequirement do
  @moduledoc "Normalizes issue execution labels and admits one frozen worker session."

  alias SymphonyElixir.Linear.Issue

  @host_only_label "execution:host-only"
  @capability_labels %{
    "capability:interactive-session" => "interactive-session",
    "capability:gui-session" => "gui-session",
    "capability:manual-pr-handoff" => "manual-pr-handoff"
  }
  @allowed_capabilities @capability_labels |> Map.values() |> Enum.sort()

  @type requirement :: String.t()
  @type evidence :: %{
          required(:execution_requirement) => requirement(),
          required(:required_capabilities) => [String.t()]
        }

  @spec from_issue(Issue.t()) :: evidence()
  def from_issue(%Issue{} = issue), do: from_labels(issue.labels || [])

  @spec from_labels([String.t()]) :: evidence()
  def from_labels(labels) when is_list(labels) do
    normalized = MapSet.new(labels, &canonical_execution_label/1)

    %{
      execution_requirement: if(MapSet.member?(normalized, @host_only_label), do: "host_only", else: "default"),
      required_capabilities:
        @capability_labels
        |> Enum.flat_map(fn {label, capability} -> if MapSet.member?(normalized, label), do: [capability], else: [] end)
        |> Enum.sort()
    }
  end

  @spec admit(Issue.t(), map()) :: :ok | {:skip, atom()}
  def admit(%Issue{} = issue, session) when is_map(session) do
    %{execution_requirement: requirement, required_capabilities: required} = from_issue(issue)
    surface = Map.fetch!(session, :execution_surface)
    capabilities = session |> Map.fetch!(:capabilities) |> capability_values() |> MapSet.new()

    case {requirement, surface, MapSet.subset?(MapSet.new(required), capabilities)} do
      {"default", "container_worker", _matches} -> :ok
      {"host_only", "host_probe", true} -> :ok
      {"host_only", "host_probe", false} -> {:skip, :required_capabilities_unavailable}
      {"host_only", _surface, _matches} -> {:skip, :host_only_surface_required}
      {"default", "host_probe", _matches} -> {:skip, :host_probe_requires_host_only}
      {_requirement, _surface, _matches} -> {:skip, :execution_surface_unavailable}
    end
  end

  @spec allowed_capabilities() :: [String.t()]
  def allowed_capabilities, do: @allowed_capabilities

  @spec normalize_capabilities(term()) :: {:ok, [String.t()]} | {:error, :invalid_host_probe_capabilities}
  def normalize_capabilities(%{"values" => values}), do: normalize_capabilities(values)

  def normalize_capabilities(values) when is_list(values) do
    normalized = values |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.sort()

    if Enum.all?(normalized, &(&1 in @allowed_capabilities)),
      do: {:ok, normalized},
      else: {:error, :invalid_host_probe_capabilities}
  end

  def normalize_capabilities(_values), do: {:error, :invalid_host_probe_capabilities}

  @spec capability_digest([String.t()]) :: String.t()
  def capability_digest(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp capability_values(%{"values" => values}) when is_list(values), do: values
  defp canonical_execution_label(label), do: label |> to_string() |> String.trim() |> String.downcase()
end

defmodule SymphonyElixir.ExecutionEvidence do
  @moduledoc "Projects immutable run execution evidence without guessing legacy values."

  @spec observable_fields(map()) :: map()
  def observable_fields(run) when is_map(run) do
    if recorded?(run) do
      %{
        execution_evidence_recorded: true,
        execution_requirement: evidence_value(run, :execution_requirement),
        execution_surface: evidence_value(run, :execution_surface),
        probe_id: evidence_value(run, :probe_id),
        worker_session_id: evidence_value(run, :worker_session_id)
      }
    else
      %{
        execution_evidence_recorded: false,
        execution_requirement: "unrecorded",
        execution_surface: "unrecorded",
        probe_id: nil,
        worker_session_id: nil
      }
    end
  end

  @spec recorded?(map()) :: boolean()
  def recorded?(run) when is_map(run), do: evidence_value(run, :execution_evidence_recorded) == true

  @spec observable_surface(map()) :: String.t()
  def observable_surface(run) when is_map(run), do: run |> observable_fields() |> Map.fetch!(:execution_surface)

  defp evidence_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

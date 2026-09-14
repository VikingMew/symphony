defmodule SymphonyElixir.Release.LegacyWorkflowCommand do
  @moduledoc false

  alias SymphonyElixir.Config.LegacyWorkflowConvergence

  @spec execute(
          LegacyWorkflowConvergence.status(),
          String.t() | nil,
          (String.t() -> {:ok, term()} | {:error, term()}),
          (String.t() -> term())
        ) :: {:ok, term()} | {:error, term()}
  def execute(status, project_slug, reconcile, output)
      when is_function(reconcile, 1) and is_function(output, 1) do
    output.(format_status(status))

    case project_slug do
      nil ->
        {:ok, status}

      slug ->
        case reconcile.(slug) do
          {:ok, result} ->
            output.("legacy instance workflow reconciliation: #{slug}")
            {:ok, result}

          {:error, _reason} = error ->
            error
        end
    end
  end

  @spec format_status(LegacyWorkflowConvergence.status()) :: String.t()
  def format_status(:zero), do: "legacy instance workflow status: zero"

  def format_status({:converged, _instance}),
    do: "legacy instance workflow status: converged"

  def format_status({:conflict, conflict}) do
    paths =
      conflict
      |> Map.fetch!("differing_paths")
      |> Enum.map_join("\n", fn difference -> "path: #{Map.fetch!(difference, "path")}" end)

    projects =
      conflict
      |> Map.fetch!("candidates")
      |> Enum.map_join("\n", fn candidate ->
        "project: id=#{Map.fetch!(candidate, "project_id")} slug=#{Map.fetch!(candidate, "project_slug")}"
      end)

    Enum.join(["legacy instance workflow status: conflict", paths, projects], "\n")
  end
end

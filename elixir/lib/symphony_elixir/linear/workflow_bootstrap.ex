defmodule SymphonyElixir.Linear.WorkflowBootstrap do
  @moduledoc """
  Creates missing Linear workflow states required by the active Symphony workflow.
  """

  require Logger

  alias SymphonyElixir.Linear.{Client, WorkflowStateValidator}

  @type result :: %{
          created: [String.t()],
          skipped: [String.t()],
          failed: [map()]
        }

  @spec create_missing_statuses(map(), [String.t()], map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def create_missing_statuses(settings, available_state_names, project_probe_data, opts \\ [])

  @spec create_missing_statuses(map(), [String.t()], map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def create_missing_statuses(settings, available_state_names, project_probe_data, opts)
      when is_map(settings) and is_list(available_state_names) and is_map(project_probe_data) do
    client = Keyword.get(opts, :client_module, client_module())

    with {:ok, team_id} <- team_id(project_probe_data) do
      validation = WorkflowStateValidator.validate(settings, available_state_names)
      missing = Map.get(validation, :missing_states, [])
      available = MapSet.new(Enum.map(available_state_names, &normalize_state/1))

      result = create_missing_states(client, team_id, missing, available)

      Logger.info(
        "linear_workflow_bootstrap team_id=#{team_id} created=#{inspect(result.created)} skipped=#{inspect(result.skipped)} failed=#{inspect(result.failed, limit: 20, printable_limit: 500)}"
      )

      {:ok, result}
    end
  end

  def create_missing_statuses(_settings, _available_state_names, _project_probe_data, _opts), do: {:error, :invalid_bootstrap_input}

  defp create_missing_states(client, team_id, missing, available) do
    missing
    |> Enum.reduce(%{created: [], skipped: [], failed: []}, fn state, acc ->
      if MapSet.member?(available, normalize_state(state)) do
        %{acc | skipped: [state | acc.skipped]}
      else
        create_state(client, team_id, state, acc)
      end
    end)
    |> finalize_result()
  end

  defp create_state(client, team_id, state, acc) do
    case client.create_workflow_state(team_id, state, type: state_type(state)) do
      {:ok, _payload} ->
        %{acc | created: [state | acc.created]}

      {:error, reason} ->
        %{acc | failed: [%{state: state, reason: format_reason(reason)} | acc.failed]}
    end
  end

  defp finalize_result(result) do
    %{
      created: Enum.sort(result.created),
      skipped: Enum.sort(result.skipped),
      failed: Enum.sort_by(result.failed, & &1.state)
    }
  end

  defp team_id(%{project: %{teams: [%{id: id} | _]}}) when is_binary(id) and id != "n/a", do: {:ok, id}
  defp team_id(%{"project" => %{"teams" => [%{"id" => id} | _]}}) when is_binary(id) and id != "n/a", do: {:ok, id}
  defp team_id(_data), do: {:error, :linear_team_not_resolved}

  defp state_type(state) do
    normalized = normalize_state(state)

    cond do
      normalized in ["done", "merged"] -> "completed"
      normalized in ["canceled", "cancelled", "duplicate"] -> "canceled"
      true -> "started"
    end
  end

  defp normalize_state(state), do: state |> to_string() |> String.trim() |> String.downcase()

  defp format_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> String.replace(~r/(Authorization|api[_-]?key|token)(["':=>,\s]+)[^,\]\}\s]+/i, "\\1\\2[REDACTED]")
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_workflow_bootstrap_client_module) ||
      Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end
end

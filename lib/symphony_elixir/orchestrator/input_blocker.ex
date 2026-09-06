defmodule SymphonyElixir.Orchestrator.InputBlocker do
  @moduledoc """
  Formats an explicit blocked agent outcome for persistence and display.

  The reason is deliberately opaque. Classification belongs to the protocol
  adapter and is never inferred here.
  """

  @type outcome :: %{required(:reason) => term(), required(:detail) => term(), optional(:references) => map()}

  @spec summary(outcome()) :: String.t()
  def summary(%{reason: reason, detail: detail}) do
    "blocked: reason=#{inspect(reason)} detail=#{inspect(detail, limit: 20, printable_limit: 1_000)}"
  end

  @spec entry(String.t(), map(), outcome(), DateTime.t()) :: map()
  def entry(issue_id, running_entry, outcome, now \\ DateTime.utc_now())
      when is_binary(issue_id) and is_map(running_entry) and is_map(outcome) do
    history = Map.get(running_entry, :session_history, [])

    %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier),
      state: get_in(running_entry, [:issue, Access.key(:state)]),
      run_id: Map.get(running_entry, :run_id),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: Map.get(running_entry, :session_id),
      blocked_at: now,
      reason: Map.fetch!(outcome, :reason),
      detail: Map.fetch!(outcome, :detail),
      references: Map.get(outcome, :references, %{}),
      session_history: history,
      session_history_total_count: Map.get(running_entry, :session_history_total_count, length(history))
    }
  end
end

defmodule SymphonyElixir.Worker.ClaimStage do
  @moduledoc "Records claim stage latency and reports the active stage to its owner."
  require Logger

  @spec measure(map(), atom(), (-> term())) :: term()
  def measure(context, stage, fun) do
    started = System.monotonic_time(:millisecond)
    GenServer.cast(context.manager, {:claim_stage, context.claim_id, stage, started})
    Logger.info("event=worker_claim_stage #{fields(context)} stage=#{stage} status=started")
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("event=worker_claim_stage #{fields(context)} stage=#{stage} status=#{status(result)} elapsed_ms=#{elapsed}#{count(result)}")
    result
  end

  defp fields(context) do
    issue = Map.get(context, :issue)
    issue_fields = if issue, do: "issue_id=#{issue.id} issue_identifier=#{issue.identifier}", else: "issue_id=n/a issue_identifier=n/a"
    "claim_id=#{context.claim_id} phase=#{context.phase} worker_id=#{context.worker_id} worker_session_id=#{context.session_id} #{issue_fields}"
  end

  defp status({:error, _reason}), do: :failed
  defp status({:skip, _reason, _evidence}), do: :skipped
  defp status(_result), do: :completed
  defp count({:ok, items}) when is_list(items), do: " count=#{length(items)}"
  defp count(_result), do: ""
end

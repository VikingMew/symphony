defmodule SymphonyElixir.Worker.Executor.DeliveryEvidence do
  @moduledoc false

  alias SymphonyElixir.StateName

  @spec completion(String.t(), [map()]) :: {:complete | :incomplete, map()} | nil
  def completion("implementation", events), do: completed(events)
  def completion("refinement", events), do: refinement(events)
  def completion(_profile, _events), do: nil

  @spec host_push_directive?(String.t()) :: boolean()
  def host_push_directive?(description) do
    description
    |> String.split("\n")
    |> Stream.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> Kernel.==("交付路径:宿主 push")
  end

  @spec completed([map()]) :: {:complete | :incomplete, map()}
  def completed(events) do
    pull_request =
      Enum.find(events, &match?(%{tool: "create_pull_request", status: "success"}, &1))

    linear_update =
      Enum.find(events, &match?(%{tool: "linear_task_update", status: "success"}, &1))

    missing =
      [pull_request_evidence_missing(pull_request), linear_update_evidence_missing(linear_update)]
      |> Enum.reject(&is_nil/1)

    completion_result(missing, pull_request)
  end

  @spec refinement([map()]) :: {:complete | :incomplete, map()}
  def refinement(events) do
    update =
      Enum.find(events, fn
        %{
          tool: "linear_task_update",
          status: "success",
          arguments: %{"target_state" => state}
        } ->
          StateName.normalize(state) == StateName.normalize("Needs Refinement Review")

        _event ->
          false
      end)

    case update do
      nil ->
        {:incomplete, %{"missing" => ["linear_task_update(target_state: Needs Refinement Review)"]}}

      _update ->
        {:complete, %{"linear_state" => "Needs Refinement Review"}}
    end
  end

  defp completion_result([], %{result: %{"url" => url} = result}) do
    evidence =
      result
      |> Map.take(["head", "head_oid"])
      |> Map.new(fn
        {"head", branch} -> {"branch", branch}
        {"head_oid", commit} -> {"commit", commit}
      end)
      |> Map.merge(%{"pr_url" => url, "linear_state" => "Ready to Merge"})

    {:complete, evidence}
  end

  defp completion_result(missing, _pull_request), do: {:incomplete, %{"missing" => missing}}

  defp pull_request_evidence_missing(nil), do: "create_pull_request"
  defp pull_request_evidence_missing(%{result: %{"url" => _url}}), do: nil
  defp pull_request_evidence_missing(%{}), do: "create_pull_request.result.url"

  defp linear_update_evidence_missing(nil), do: "linear_task_update"

  defp linear_update_evidence_missing(%{arguments: %{"target_state" => state}}) do
    if StateName.normalize(state) == StateName.normalize("Ready to Merge"),
      do: nil,
      else: "linear_task_update.arguments.target_state"
  end

  defp linear_update_evidence_missing(%{}), do: "linear_task_update.arguments.target_state"
end

defmodule SymphonyElixir.Nap.Results do
  @moduledoc """
  Aggregates operator issue-creation audit events into a task summary.
  """

  alias SymphonyElixir.Payload

  @type summary :: %{
          created: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          issues: [map()]
        }

  @spec aggregate([map()]) :: summary()
  def aggregate(events) when is_list(events) do
    events
    |> Enum.filter(&issue_create_event?/1)
    |> Enum.reduce(empty_summary(), &aggregate_event/2)
    |> Map.update!(:issues, &Enum.reverse/1)
  end

  defp empty_summary, do: %{created: 0, skipped: 0, failed: 0, issues: []}

  defp issue_create_event?(event) do
    payload = Payload.get_any(event, [:payload, "payload"], %{})

    Payload.get_any(event, [:event_type, "event_type"]) == "linear.tool_call" and
      Payload.get_any(payload, [:tool, "tool"]) == "linear_issue_create"
  end

  defp aggregate_event(event, summary) do
    payload = Payload.get_any(event, [:payload, "payload"], %{})

    case Payload.get_any(payload, [:status, "status"]) do
      "success" -> record_created(summary, Payload.get_any(payload, [:result, "result"]))
      "skipped" -> Map.update!(summary, :skipped, &(&1 + 1))
      "failure" -> Map.update!(summary, :failed, &(&1 + 1))
      _status -> summary
    end
  end

  defp record_created(summary, issue) when is_map(issue) do
    summary
    |> Map.update!(:created, &(&1 + 1))
    |> Map.update!(:issues, &[issue | &1])
  end

  defp record_created(summary, _issue), do: Map.update!(summary, :created, &(&1 + 1))
end

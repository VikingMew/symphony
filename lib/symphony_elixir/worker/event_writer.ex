defmodule SymphonyElixir.Worker.EventWriter do
  @moduledoc "Persists a worker event and its run transition atomically, outside the lease owner."

  alias SymphonyElixir.{RunFailure, RunLifecycle}

  @spec write(module(), map(), {:ok, map()} | {:error, term()}) ::
          {:ok, {map(), :written | :replayed}} | {:error, term()}
  def write(persistence, request, admission) do
    persistence.worker_event_transaction(fn ->
      case persistence.get_event(request.id) do
        nil -> write_new(persistence, request, admission)
        {:error, reason} -> {:error, reason}
        event -> replay(event, request)
      end
    end)
  end

  defp write_new(_persistence, _request, {:error, reason}), do: {:error, reason}

  defp write_new(persistence, request, {:ok, assignment}) do
    attrs = event_attrs(assignment, request.event_type, event_payload(request, assignment.correlation))

    with {:ok, event} <- persistence.record_event(Map.put(attrs, :id, request.id)),
         :ok <- finish_run(persistence, assignment, request) do
      {:ok, {event, :written}}
    end
  end

  defp replay(event, request) do
    correlation = Map.get(event.payload, "correlation", %{})
    supplied = Map.get(request.payload, "correlation", %{})

    if correlation["worker_id"] == request.worker_id and
         correlation["worker_session_id"] == request.session_id and
         correlation["assignment_id"] == request.assignment_id and
         event.event_type == request.event_type and
         Enum.all?(supplied, fn {key, value} -> not Map.has_key?(correlation, key) or correlation[key] == value end) and
         event.payload == event_payload(request, correlation) do
      {:ok, {event, :replayed}}
    else
      {:error, :event_id_conflict}
    end
  end

  defp finish_run(_persistence, _assignment, %{terminal: nil}), do: :ok

  defp finish_run(persistence, assignment, request) do
    status = terminal_status(request)
    attrs = if request.summary, do: %{execution_summary: request.summary}, else: %{}
    fields = RunFailure.terminal_fields(request.terminal)

    terminal_event =
      event_attrs(assignment, "run.#{status}", %{
        "failure_reason" => fields.failure_reason,
        "failure_evidence" => fields.failure_evidence
      })

    with {:ok, _run} <- RunLifecycle.finish_run(persistence, assignment.run_id, status, request.terminal, attrs: attrs),
         {:ok, _event} <- persistence.record_event(terminal_event) do
      :ok
    end
  end

  defp terminal_status(%{terminal: :completed}), do: "completed"
  defp terminal_status(%{terminal: %RunFailure{classification: "cancelled"}}), do: "cancelled"
  defp terminal_status(%{summary: %{"outcome" => "blocked"}}), do: "blocked"
  defp terminal_status(%{terminal: %RunFailure{}}), do: "failed"

  defp event_payload(request, correlation) do
    payload = Map.put(request.payload, "correlation", correlation)
    payload = if request.summary, do: Map.put(payload, "summary", request.summary), else: payload

    case request.terminal do
      nil ->
        payload

      terminal ->
        fields = RunFailure.terminal_fields(terminal)
        Map.merge(payload, %{"failure_reason" => fields.failure_reason, "failure_evidence" => fields.failure_evidence})
    end
  end

  defp event_attrs(assignment, type, payload) do
    %{
      project_id: assignment.project_id,
      run_id: assignment.run_id,
      issue_identifier: assignment.issue_identifier,
      event_type: type,
      payload: Map.put_new(payload, "correlation", assignment.correlation)
    }
  end
end

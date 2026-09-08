defmodule SymphonyElixir.Worker.LinearToolAuditRecorder do
  @moduledoc "Forwards execution-worker Linear tool audits to the owning Panel."

  @type context :: %{
          required(:client) => module(),
          required(:config) => SymphonyElixir.Worker.Config.t(),
          required(:identity) => map(),
          required(:task_id) => String.t(),
          required(:correlation) => map()
        }

  @spec record(context(), map(), map()) :: :ok | {:error, term()}
  def record(context, attrs, payload) do
    event_payload = Map.put(payload, :correlation, context.correlation)

    case context.client.event(
           context.config,
           context.identity,
           context.task_id,
           Map.fetch!(attrs, :event_type),
           event_payload
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

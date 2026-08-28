defmodule SymphonyElixir.Worker.Client do
  @moduledoc "Authenticated worker-v1 HTTP client."

  alias SymphonyElixir.Worker.Config

  @protocol "worker-api-v1"

  @spec register(Config.t()) :: {:ok, map()} | {:error, term()}
  def register(config) do
    request(config, :post, "/api/worker/v1/register",
      json: %{
        worker_name: config.worker_name,
        protocol_version: @protocol,
        worker_version: config.source_revision,
        instance_id: config.worker_name,
        capabilities: %{"execution" => ["v1"]}
      },
      headers: [{"authorization", "Bearer #{config.registration_token}"}]
    )
  end

  @spec claim(Config.t(), map()) :: {:ok, map()} | {:error, term()}
  def claim(config, identity), do: request(config, :post, "/api/worker/v1/tasks/claim", json: identity)

  @spec heartbeat(Config.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def heartbeat(config, identity, payload), do: request(config, :post, "/api/worker/v1/heartbeat", json: Map.merge(identity, payload))

  @spec event(Config.t(), map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def event(config, identity, task_id, event_type, payload) do
    request(config, :post, "/api/worker/v1/tasks/#{task_id}/events", json: Map.merge(identity, %{task_id: task_id, event_type: event_type, payload: payload}))
  end

  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol

  defp request(config, method, path, options) do
    options = Keyword.merge([method: method, url: config.panel_url <> path, retry: :transient, max_retries: 3], options)

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end
end

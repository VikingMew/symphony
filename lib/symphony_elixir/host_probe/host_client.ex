defmodule SymphonyElixir.HostProbe.HostClient do
  @moduledoc "Bearer-authenticated fixed-loopback worker-v1 client for the host probe."

  alias SymphonyElixir.HostProbe.HostConfig

  @protocol "worker-api-v1"

  @spec register_host_probe(HostConfig.host_config()) :: {:ok, map()} | {:error, term()}
  def register_host_probe(config) do
    with {:ok, response} <-
           send_host_request(config, :post, "/api/worker/v1/register",
             json: %{
               execution_surface: "host_probe",
               probe_id: config.probe_id,
               worker_name: config.worker_name,
               protocol_version: @protocol,
               worker_version: config.source_revision,
               total_slots: 1,
               capabilities: %{"values" => config.capabilities}
             }
           ),
         :ok <- validate_host_registration(config, response) do
      {:ok, response}
    end
  end

  @spec claim_host_assignment(HostConfig.host_config(), map()) :: {:ok, map()} | {:error, term()}
  def claim_host_assignment(config, identity), do: send_host_request(config, :post, "/api/worker/v1/tasks/claim", json: identity)

  @spec heartbeat_host_assignment(HostConfig.host_config(), map(), map()) :: {:ok, map()} | {:error, term()}
  def heartbeat_host_assignment(config, identity, payload) do
    send_host_request(config, :post, "/api/worker/v1/heartbeat", json: Map.merge(identity, payload))
  end

  @spec send_host_event(HostConfig.host_config(), map(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def send_host_event(config, identity, task_id, event_type, payload) do
    payload = Map.put_new_lazy(payload, "event_id", &Ecto.UUID.generate/0)

    send_host_request(config, :post, "/api/worker/v1/tasks/#{task_id}/events", json: Map.merge(identity, %{task_id: task_id, event_type: event_type, payload: payload}))
  end

  @spec retry_host_terminal?(term()) :: boolean()
  def retry_host_terminal?({:transport_error, _reason}), do: true
  def retry_host_terminal?({:http_error, 429, _body}), do: true
  def retry_host_terminal?({:http_error, status, _body}) when status in 500..599, do: true
  def retry_host_terminal?(_reason), do: false

  @spec host_protocol_version() :: String.t()
  def host_protocol_version, do: @protocol

  defp validate_host_registration(config, response) do
    expected = %{
      "execution_surface" => "host_probe",
      "probe_id" => config.probe_id,
      "capability_digest" => config.capability_digest,
      "heartbeat_interval_seconds" => config.heartbeat_seconds,
      "lease_duration_seconds" => config.lease_seconds,
      "accepted_protocol_version" => @protocol
    }

    if Enum.all?(expected, fn {key, value} -> response[key] == value end),
      do: :ok,
      else: {:error, :host_probe_registration_mismatch}
  end

  defp send_host_request(config, method, path, options) do
    request_options =
      [
        method: method,
        url: config.panel_url <> path,
        retry: false,
        headers: [{"authorization", "Bearer #{config.registration_token}"}]
      ]
      |> Keyword.merge(config.request_options)
      |> Keyword.merge(options)

    case Req.request(request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end
end

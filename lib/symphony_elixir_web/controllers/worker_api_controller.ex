defmodule SymphonyElixirWeb.WorkerApiController do
  @moduledoc """
  Versioned HTTP API used by external Symphony workers.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.PersistenceProvider

  @spec register(Conn.t(), map()) :: Conn.t()
  def register(conn, params) do
    with :ok <- verify_registration_token(conn),
         {:ok, %{worker: worker, session: session}} <- persistence().register_worker(params) do
      json(conn, %{
        worker_id: worker.id,
        session_id: session.id,
        heartbeat_interval_seconds: persistence().worker_heartbeat_interval_seconds(),
        lease_duration_seconds: persistence().worker_lease_duration_seconds(),
        server_time: DateTime.utc_now(),
        accepted_protocol_version: persistence().worker_protocol_version()
      })
    else
      {:error, :unauthorized} ->
        error_response(conn, 401, "worker_unauthorized", "Worker registration token is invalid")

      {:error, :unsupported_protocol_version} ->
        error_response(conn, 426, "unsupported_worker_protocol", "Worker protocol version is not supported")

      {:error, reason} ->
        error_response(conn, 422, "worker_registration_failed", inspect(reason))
    end
  end

  @spec claim(Conn.t(), map()) :: Conn.t()
  def claim(conn, params) do
    with {:ok, worker_id, session_id} <- worker_identity(conn, params),
         {:ok, result} <- persistence().claim_task(worker_id, session_id, params) do
      case result do
        nil ->
          json(conn, %{task: nil, poll_after_seconds: 5})

        %{task: task, lease: lease} ->
          json(conn, %{
            task_id: task.id,
            lease_id: lease.id,
            lease_expires_at: lease.expires_at,
            project_id: task.project_id,
            run_id: task.run_id,
            workflow_version_id: task.workflow_version_id,
            issue: %{identifier: task.issue_identifier},
            execution: task.payload || %{}
          })
      end
    else
      {:error, reason} -> worker_error(conn, reason)
    end
  end

  @spec heartbeat(Conn.t(), map()) :: Conn.t()
  def heartbeat(conn, params) do
    with {:ok, worker_id, session_id} <- worker_identity(conn, params),
         {:ok, payload} <- persistence().heartbeat(worker_id, session_id, params) do
      json(conn, payload)
    else
      {:error, reason} -> worker_error(conn, reason)
    end
  end

  @spec task_event(Conn.t(), map()) :: Conn.t()
  def task_event(conn, %{"task_id" => task_id, "event_type" => event_type} = params) do
    with {:ok, worker_id, session_id} <- worker_identity(conn, params),
         {:ok, event} <-
           persistence().record_worker_task_event(worker_id, session_id, task_id, event_type, Map.get(params, "payload", %{})) do
      conn
      |> put_status(202)
      |> json(%{event_id: event.id, accepted: true})
    else
      {:error, reason} -> worker_error(conn, reason)
    end
  end

  def task_event(conn, _params) do
    error_response(conn, 422, "invalid_worker_event", "event_type is required")
  end

  defp verify_registration_token(conn) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _ -> conn |> get_req_header("x-symphony-worker-token") |> List.first()
      end

    if persistence().valid_worker_registration_token?(token), do: :ok, else: {:error, :unauthorized}
  end

  defp worker_identity(conn, params) do
    worker_id = header_or_param(conn, params, "x-symphony-worker-id", "worker_id")
    session_id = header_or_param(conn, params, "x-symphony-worker-session", "session_id")
    protocol = header_or_param(conn, params, "x-symphony-worker-protocol", "protocol_version")

    cond do
      protocol not in [nil, persistence().worker_protocol_version()] ->
        {:error, :unsupported_protocol_version}

      is_nil(worker_id) or is_nil(session_id) ->
        {:error, :worker_session_not_found}

      true ->
        {:ok, worker_id, session_id}
    end
  end

  defp header_or_param(conn, params, header, param) do
    conn |> get_req_header(header) |> List.first() || Map.get(params, param)
  end

  defp persistence, do: PersistenceProvider.module()

  defp worker_error(conn, :unsupported_protocol_version) do
    error_response(conn, 426, "unsupported_worker_protocol", "Worker protocol version is not supported")
  end

  defp worker_error(conn, :worker_session_not_found) do
    error_response(conn, 401, "worker_session_not_found", "Worker session is not active")
  end

  defp worker_error(conn, :lease_conflict) do
    error_response(conn, 409, "lease_conflict", "Task is already leased")
  end

  defp worker_error(conn, :lease_expired) do
    error_response(conn, 409, "lease_expired", "Task lease has expired")
  end

  defp worker_error(conn, :lease_not_active) do
    error_response(conn, 409, "lease_not_active", "Worker does not hold an active lease for this task")
  end

  defp worker_error(conn, reason) do
    error_response(conn, 422, "worker_api_error", inspect(reason))
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end

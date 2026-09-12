defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc """
  Authenticated JSON API for Symphony runtime controls.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.WebRuntime

  @spec listening(Conn.t(), map()) :: Conn.t()
  def listening(conn, %{"mode" => "all"}),
    do: control_response(conn, Orchestrator.start_listening(WebRuntime.orchestrator()))

  def listening(conn, %{"mode" => "refine_only"}),
    do: control_response(conn, Orchestrator.start_refine_only_listening(WebRuntime.orchestrator()))

  def listening(conn, %{"mode" => "off"}),
    do: control_response(conn, Orchestrator.stop_listening(WebRuntime.orchestrator()))

  def listening(conn, _params),
    do: error_response(conn, 400, "invalid_parameter", "mode must be all, refine_only, or off")

  @spec reset_environment_failure_circuit(Conn.t(), map()) :: Conn.t()
  def reset_environment_failure_circuit(conn, _params),
    do: control_response(conn, Orchestrator.reset_environment_failure_circuit(WebRuntime.orchestrator()))

  @spec force_stop(Conn.t(), map()) :: Conn.t()
  def force_stop(conn, _params),
    do: control_response(conn, Orchestrator.force_stop_all(WebRuntime.orchestrator()))

  @spec cancel_task(Conn.t(), map()) :: Conn.t()
  def cancel_task(conn, params) do
    case optional_project_id(params) do
      {:ok, project_id} ->
        control_response(conn, Orchestrator.cancel_current_task(project_id, WebRuntime.orchestrator()))

      :error ->
        invalid_project_id(conn)
    end
  end

  @spec nap(Conn.t(), map()) :: Conn.t()
  def nap(conn, params) do
    case optional_project_id(params) do
      {:ok, project_id} ->
        control_response(conn, Orchestrator.request_nap(WebRuntime.orchestrator(), project_id))

      :error ->
        invalid_project_id(conn)
    end
  end

  @spec daydream(Conn.t(), map()) :: Conn.t()
  def daydream(conn, params) do
    case optional_project_id(params) do
      {:ok, project_id} ->
        control_response(conn, Orchestrator.request_day_dreaming(WebRuntime.orchestrator(), project_id))

      :error ->
        invalid_project_id(conn)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params),
    do: error_response(conn, 405, "method_not_allowed", "Method not allowed")

  defp optional_project_id(params) do
    case Map.fetch(params, "project_id") do
      :error -> {:ok, nil}
      {:ok, project_id} when is_binary(project_id) -> non_empty_project_id(project_id)
      {:ok, _project_id} -> :error
    end
  end

  defp non_empty_project_id(project_id) do
    case String.trim(project_id) do
      "" -> :error
      _value -> {:ok, project_id}
    end
  end

  defp invalid_project_id(conn),
    do: error_response(conn, 400, "invalid_parameter", "project_id must be a non-empty string")

  defp control_response(conn, :unavailable),
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp control_response(conn, result) when is_map(result), do: json(conn, result)

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end

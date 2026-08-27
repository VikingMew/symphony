defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.ObservabilityHistory
  alias SymphonyElixirWeb.{Presenter, WebRuntime}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(WebRuntime.orchestrator(), WebRuntime.snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    live = Presenter.live_issue_payload(issue_identifier, WebRuntime.orchestrator(), WebRuntime.snapshot_timeout_ms())
    history = ObservabilityHistory.fetch(issue_identifier)
    issue_response(conn, live, history)
  end

  @spec runs(Conn.t(), map()) :: Conn.t()
  def runs(conn, params) do
    with {:ok, issue_identifier} <- required_issue_identifier(params),
         {:ok, limit} <- ObservabilityHistory.parse_limit(Map.get(params, "limit")),
         {:ok, %{known?: true} = history} <- ObservabilityHistory.fetch(issue_identifier, limit: limit) do
      json(conn, %{
        issue_identifier: issue_identifier,
        issue: history.issue,
        latest_run: history.latest_run,
        runs: history.runs,
        events: history.events
      })
    else
      {:error, :missing_issue_identifier} ->
        error_response(conn, 400, "missing_parameter", "issue_identifier is required")

      {:error, :invalid_limit} ->
        error_response(conn, 400, "invalid_parameter", "limit must be a positive integer")

      {:ok, %{known?: false}} ->
        error_response(conn, 404, "history_not_found", "Issue history not found")

      {:error, reason} ->
        persistence_error_response(conn, reason)
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(WebRuntime.orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp issue_response(conn, {:ok, live_payload}, {:ok, history}) do
    json(conn, Presenter.with_persisted_history(live_payload, history))
  end

  defp issue_response(conn, {:ok, live_payload}, {:error, reason}) do
    history_error = reason |> persistence_error() |> Map.take([:code, :message])
    json(conn, Presenter.with_history_error(live_payload, history_error))
  end

  defp issue_response(conn, :not_found, {:ok, %{known?: true} = history}) do
    json(conn, Presenter.persisted_issue_payload(history))
  end

  defp issue_response(conn, :not_found, {:ok, %{known?: false}}) do
    error_response(conn, 404, "issue_not_found", "Issue not found")
  end

  defp issue_response(conn, :not_found, {:error, reason}), do: persistence_error_response(conn, reason)

  defp issue_response(conn, {:error, _snapshot_error}, {:ok, %{known?: true} = history}) do
    json(conn, Presenter.persisted_issue_payload(history))
  end

  defp issue_response(conn, {:error, snapshot_error}, {:ok, %{known?: false}}) do
    error_response(conn, 503, "orchestrator_unavailable", snapshot_error_message(snapshot_error))
  end

  defp issue_response(conn, {:error, _snapshot_error}, {:error, reason}), do: persistence_error_response(conn, reason)

  defp required_issue_identifier(%{"issue_identifier" => identifier}) when is_binary(identifier) do
    case String.trim(identifier) do
      "" -> {:error, :missing_issue_identifier}
      value -> {:ok, value}
    end
  end

  defp required_issue_identifier(_params), do: {:error, :missing_issue_identifier}

  defp persistence_error_response(conn, reason) do
    %{status: status, code: code, message: message} = persistence_error(reason)
    error_response(conn, status, code, message)
  end

  defp persistence_error(:repo_unavailable),
    do: %{status: 503, code: "database_unavailable", message: "Database is unavailable"}

  defp persistence_error(:timeout),
    do: %{status: 503, code: "database_timeout", message: "Database read timed out"}

  defp persistence_error({:query_failed, _reason}),
    do: %{status: 503, code: "database_query_failed", message: "Database query failed"}

  defp snapshot_error_message(:snapshot_timeout), do: "Runtime snapshot timed out"
  defp snapshot_error_message(:snapshot_unavailable), do: "Runtime snapshot is unavailable"
end

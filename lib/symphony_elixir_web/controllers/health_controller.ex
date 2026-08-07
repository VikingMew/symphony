defmodule SymphonyElixirWeb.HealthController do
  @moduledoc """
  Health endpoints for reverse proxy and Kubernetes probes.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Persistence
  alias SymphonyElixirWeb.ProxyHeaders

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    json(conn, %{
      "status" => "ok",
      "checks" => %{"web" => "ok"},
      "external_url" => ProxyHeaders.external_url(conn, conn.request_path),
      "proxy_headers_trusted" => conn.private[:symphony_proxy_headers_trusted] == true
    })
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    persistence = persistence()
    repo_ready? = safe_repo_available?(persistence)
    workflow_state = workflow_state(persistence)
    status = if repo_ready?, do: "ready", else: "not_ready"

    conn
    |> put_status(if(repo_ready?, do: 200, else: 503))
    |> json(%{
      "status" => status,
      "checks" => %{
        "web" => "ok",
        "database" => if(repo_ready?, do: "ok", else: "unavailable"),
        "workflow" => workflow_state
      },
      "external_url" => ProxyHeaders.external_url(conn, conn.request_path),
      "proxy_headers_trusted" => conn.private[:symphony_proxy_headers_trusted] == true
    })
  end

  defp safe_repo_available?(persistence) do
    function_exported?(persistence, :repo_available?, 0) and persistence.repo_available?()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp workflow_state(persistence) do
    if function_exported?(persistence, :active_workflow_version, 0) do
      case persistence.active_workflow_version() do
        nil -> "setup_required"
        _version -> "configured"
      end
    else
      "unknown"
    end
  rescue
    _ -> "unknown"
  catch
    _, _ -> "unknown"
  end

  defp persistence, do: Application.get_env(:symphony_elixir, :persistence_module, Persistence)
end

defmodule SymphonyElixirWeb.AuthPlug do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias SymphonyElixir.Auth

  @spec require_browser_auth(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_browser_auth(conn, _opts) do
    if authenticated?(conn) do
      conn
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end

  @spec require_api_auth(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_api_auth(conn, _opts) do
    if authenticated?(conn) do
      conn
    else
      conn
      |> put_status(401)
      |> json(%{error: %{code: "authentication_required", message: "Authentication required"}})
      |> halt()
    end
  end

  defp authenticated?(conn) do
    !Auth.enabled?() or get_session(conn, :symphony_user) != nil
  end
end

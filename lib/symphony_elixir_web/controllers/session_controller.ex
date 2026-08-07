defmodule SymphonyElixirWeb.SessionController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  alias SymphonyElixir.Auth

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params) do
    html(conn, login_page(nil))
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"username" => username, "password" => password}) do
    case Auth.authenticate(username, password) do
      {:ok, user} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:symphony_user, user.username)
        |> redirect(to: "/")

      {:error, :not_configured} ->
        conn
        |> put_status(503)
        |> html(login_page("Authentication is enabled but no admin user is configured."))

      {:error, :invalid_credentials} ->
        conn
        |> put_status(401)
        |> html(login_page("Invalid username or password."))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> html(login_page("Username and password are required."))
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  defp login_page(error) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    error_html =
      if error do
        ~s(<p class="login-error">#{error}</p>)
      else
        ""
      end

    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Symphony Login</title>
        <style>
          body { margin: 0; font-family: system-ui, sans-serif; background: #f7f7f4; color: #1f2933; }
          main { max-width: 360px; margin: 12vh auto; padding: 24px; }
          label { display: block; font-size: 13px; font-weight: 600; margin: 14px 0 6px; }
          input { width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid #c9d1d9; border-radius: 6px; font: inherit; }
          button { margin-top: 18px; width: 100%; padding: 10px 12px; border: 0; border-radius: 6px; background: #1f6feb; color: white; font-weight: 700; }
          .login-error { padding: 10px 12px; border-radius: 6px; background: #ffecec; color: #8a1f11; }
        </style>
      </head>
      <body>
        <main>
          <h1>Symphony</h1>
          #{error_html}
          <form method="post" action="/login">
            <input type="hidden" name="_csrf_token" value="#{csrf_token}">
            <label for="username">Username</label>
            <input id="username" name="username" autocomplete="username" required>
            <label for="password">Password</label>
            <input id="password" name="password" type="password" autocomplete="current-password" required>
            <button type="submit">Sign in</button>
          </form>
        </main>
      </body>
    </html>
    """
  end
end

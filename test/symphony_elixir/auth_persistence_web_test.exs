defmodule SymphonyElixir.AuthPersistenceWebTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_session: 2]

  alias SymphonyElixir.Auth
  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous_auth = Application.get_env(:symphony_elixir, :auth)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)

    on_exit(fn ->
      restore_app_env(:auth, previous_auth)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:persistence_module, previous_persistence)
    end)

    :ok
  end

  test "password hashes verify and reject invalid passwords" do
    hash = Auth.hash_password("correct horse")

    assert hash =~ "pbkdf2_sha256$"
    assert Auth.verify("correct horse", hash)
    refute Auth.verify("wrong", hash)
    refute Auth.verify("correct horse", "plaintext")
    refute Auth.verify("correct horse", "pbkdf2_sha256$bad$bad$bad")
    refute Auth.verify(nil, hash)
  end

  test "auth reports disabled unconfigured and invalid inputs" do
    Application.put_env(:symphony_elixir, :auth, enabled: false)
    refute Auth.enabled?()
    refute Auth.configured?()
    assert {:error, :not_configured} = Auth.authenticate("admin", "secret")
    assert {:error, :invalid_credentials} = Auth.authenticate(nil, "secret")

    Application.put_env(:symphony_elixir, :auth, enabled: true, username: "admin", password: "secret")
    assert Auth.enabled?()
    assert Auth.configured?()
    assert {:ok, %{username: "admin"}} = Auth.authenticate("admin", "secret")
    assert {:error, :invalid_credentials} = Auth.authenticate("other", "secret")
  end

  test "browser and api routes require auth when enabled" do
    Application.put_env(:symphony_elixir, :auth,
      enabled: true,
      username: "admin",
      password_hash: Auth.hash_password("secret")
    )

    start_test_endpoint()

    conn = get(build_conn(), "/")
    assert redirected_to(conn) == "/login"

    assert %{"error" => %{"code" => "authentication_required"}} =
             build_conn()
             |> get("/api/v1/state")
             |> json_response(401)

    assert %{"error" => %{"code" => "authentication_required"}} =
             build_conn()
             |> get("/api/v1/runs?issue_identifier=SYM-3")
             |> json_response(401)
  end

  test "valid login creates a session and logout clears it" do
    Application.put_env(:symphony_elixir, :auth,
      enabled: true,
      username: "admin",
      password_hash: Auth.hash_password("secret")
    )

    start_test_endpoint()

    conn =
      build_conn()
      |> init_test_session(%{})
      |> post("/login", %{"username" => "admin", "password" => "secret"})

    assert redirected_to(conn) == "/"
    assert get_session(conn, :symphony_user) == "admin"

    conn = delete(conn, "/logout")
    assert redirected_to(conn) == "/login"

    conn = conn |> recycle() |> get("/")
    assert redirected_to(conn) == "/login"
  end

  test "login page and invalid login states render actionable errors" do
    Application.put_env(:symphony_elixir, :auth,
      enabled: true,
      username: "admin",
      password_hash: Auth.hash_password("secret")
    )

    start_test_endpoint()

    assert html_response(get(build_conn(), "/login"), 200) =~ "Sign in"

    assert build_conn()
           |> init_test_session(%{})
           |> post("/login", %{})
           |> html_response(400) =~ "Username and password are required."

    assert build_conn()
           |> init_test_session(%{})
           |> post("/login", %{"username" => "admin", "password" => "wrong"})
           |> html_response(401) =~ "Invalid username or password."

    Application.put_env(:symphony_elixir, :auth, enabled: true, username: "admin")

    assert build_conn()
           |> init_test_session(%{})
           |> post("/login", %{"username" => "admin", "password" => "secret"})
           |> html_response(503) =~ "Authentication is enabled but no admin user is configured."
  end

  test "auth can read persisted user through fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :auth, enabled: true, username: "admin")
    FakePersistence.reset!()
    FakePersistence.put_user("admin", %{username: "admin", password_hash: Auth.hash_password("secret")})

    assert Auth.configured?()
    assert {:ok, %{username: "admin"}} = Auth.authenticate("admin", "secret")
    assert {:error, :invalid_credentials} = Auth.authenticate("admin", "wrong")
  end

  test "dashboard exposes unified settings navigation" do
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(class="top-banner")
    assert html =~ "Symphony"
    assert html =~ "Operations Console"
    assert html =~ ~s(aria-current="page")
    assert html =~ "Dashboard"
    assert html =~ "Settings"
    assert html =~ ~s(href="/settings")
    refute html =~ ~s(href="/workflows")
    refute html =~ ~s(href="/agent-settings")

    {:ok, _settings_view, settings_html} = live(build_conn(), "/settings/agents")
    assert settings_html =~ ~s(class="top-banner")
    assert settings_html =~ ~s(href="/")
    assert settings_html =~ ~s(aria-current="page")
    assert settings_html =~ ~s(href="/settings/projects")
    refute settings_html =~ ~s(href="/settings/workflow")
    assert settings_html =~ ~s(href="/settings/agents")
    assert settings_html =~ ~s(href="/settings/runtime")
    assert settings_html =~ "Profile Configuration"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

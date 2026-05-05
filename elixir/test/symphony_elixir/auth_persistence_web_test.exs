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

  test "dashboard exposes workflow settings navigation" do
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Dashboard"
    assert html =~ "Workflows"
    assert html =~ ~s(href="/workflows")

    {:ok, _workflow_view, workflow_html} = live(build_conn(), "/workflows")
    assert workflow_html =~ "Raw WORKFLOW.md"
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

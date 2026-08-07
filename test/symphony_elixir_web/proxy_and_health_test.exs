defmodule SymphonyElixirWeb.ProxyAndHealthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous_proxy = Application.get_env(:symphony_elixir, :proxy)
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_repo_available = Application.get_env(:symphony_elixir, :fake_persistence)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: true)
    FakePersistence.reset!()
    start_test_endpoint()

    on_exit(fn ->
      restore_app_env(:proxy, previous_proxy)
      restore_app_env(:persistence_module, previous_persistence)
      restore_app_env(:fake_persistence, previous_repo_available)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "liveness ignores spoofed forwarded headers unless trust is enabled" do
    Application.put_env(:symphony_elixir, :proxy, trust_x_forwarded_headers: false)

    conn =
      build_conn()
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-host", "symphony.example.com")
      |> get("/health/live")

    payload = json_response(conn, 200)

    assert payload["status"] == "ok"
    assert payload["proxy_headers_trusted"] == false
    assert payload["external_url"] == "http://www.example.com/health/live"
  end

  test "trusted forwarded proto host port and prefix affect external URL" do
    Application.put_env(:symphony_elixir, :proxy, trust_x_forwarded_headers: true)

    conn =
      build_conn()
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-host", "symphony.example.com")
      |> put_req_header("x-forwarded-port", "443")
      |> put_req_header("x-forwarded-prefix", "/symphony")
      |> get("/health/live")

    payload = json_response(conn, 200)

    assert payload["proxy_headers_trusted"] == true
    assert payload["external_url"] == "https://symphony.example.com/symphony/health/live"
  end

  test "readiness reports database and setup state without secrets" do
    conn = get(build_conn(), "/health/ready")
    payload = json_response(conn, 200)

    assert payload["status"] == "ready"
    assert payload["checks"]["database"] == "ok"
    assert payload["checks"]["workflow"] == "setup_required"
    refute inspect(payload) =~ "token"
  end

  test "readiness fails closed when database is unavailable" do
    Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: false)

    conn = get(build_conn(), "/health/ready")
    payload = json_response(conn, 503)

    assert payload["status"] == "not_ready"
    assert payload["checks"]["database"] == "unavailable"
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

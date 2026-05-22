defmodule SymphonyElixirWeb.ProxyHeadersTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias SymphonyElixirWeb.ProxyHeaders

  setup do
    previous_proxy = Application.get_env(:symphony_elixir, :proxy)
    previous_trust = System.get_env("SYMPHONY_TRUST_X_FORWARDED_HEADERS")
    previous_public_url = System.get_env("SYMPHONY_PUBLIC_URL")

    on_exit(fn ->
      restore_app_env(:proxy, previous_proxy)
      restore_env("SYMPHONY_TRUST_X_FORWARDED_HEADERS", previous_trust)
      restore_env("SYMPHONY_PUBLIC_URL", previous_public_url)
    end)

    :ok
  end

  test "ignores forwarded headers by default" do
    Application.put_env(:symphony_elixir, :proxy, [])

    conn =
      conn(:get, "/runs")
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-host", "public.example:9443")
      |> ProxyHeaders.call([])

    refute conn.private.symphony_proxy_headers_trusted
    assert conn.scheme == :http
    assert conn.host == "www.example.com"
  end

  test "trusted forwarded headers rewrite scheme host port and prefix" do
    Application.put_env(:symphony_elixir, :proxy, trust_x_forwarded_headers: true)

    conn =
      conn(:get, "/runs")
      |> put_req_header("x-forwarded-proto", "https, http")
      |> put_req_header("x-forwarded-host", "public.example:9443")
      |> put_req_header("x-forwarded-port", "9444")
      |> put_req_header("x-forwarded-prefix", "/symphony/")
      |> ProxyHeaders.call([])

    assert conn.private.symphony_proxy_headers_trusted
    assert conn.scheme == :https
    assert conn.host == "public.example"
    assert conn.port == 9444
    assert conn.script_name == ["symphony"]
    assert ProxyHeaders.external_url(conn, "runs") == "https://public.example:9444/symphony/runs"
  end

  test "public url provides external URL when forwarded headers are not trusted" do
    Application.put_env(:symphony_elixir, :proxy, public_url: "https://ops.example/symphony")

    conn =
      conn(:get, "/")
      |> ProxyHeaders.call([])

    refute conn.private.symphony_proxy_headers_trusted
    assert conn.scheme == :https
    assert conn.host == "ops.example"
    assert conn.port == 443
    assert conn.script_name == ["symphony"]
    assert ProxyHeaders.external_url(conn, "/analytics") == "https://ops.example/symphony/analytics"
  end

  test "environment flags enable trusted forwarding and public url fallback" do
    Application.put_env(:symphony_elixir, :proxy, [])
    System.put_env("SYMPHONY_TRUST_X_FORWARDED_HEADERS", "yes")
    assert ProxyHeaders.trusted?()

    System.delete_env("SYMPHONY_TRUST_X_FORWARDED_HEADERS")
    System.put_env("SYMPHONY_PUBLIC_URL", "http://external.example/base")

    assert %URI{scheme: "http", host: "external.example", path: "/base"} = ProxyHeaders.public_url()
  end

  test "external url omits default ports and normalizes non-binary paths" do
    https = %{conn(:get, "/") | scheme: :https, host: "secure.example", port: 443}
    http = %{conn(:get, "/") | scheme: :http, host: "plain.example", port: 80}

    assert ProxyHeaders.external_url(https, nil) == "https://secure.example/"
    assert ProxyHeaders.external_url(http, "/ready") == "http://plain.example/ready"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

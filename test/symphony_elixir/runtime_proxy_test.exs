defmodule SymphonyElixir.RuntimeProxyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RuntimeProxy

  setup do
    previous_proxy_env = Map.new(RuntimeProxy.proxy_env_names(), &{&1, System.get_env(&1)})
    Enum.each(RuntimeProxy.proxy_env_names(), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_proxy_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "exports proxy environment for ports and remote shells" do
    System.put_env("HTTP_PROXY", " http://proxy.example.test:8080 ")
    System.put_env("NO_PROXY", "localhost")
    System.put_env("HTTPS_PROXY", "http://user's:pass@proxy.example.test:8443")

    assert {"HTTP_PROXY", "http://proxy.example.test:8080"} in RuntimeProxy.proxy_env()
    assert {~c"HTTP_PROXY", ~c"http://proxy.example.test:8080"} in RuntimeProxy.port_env()

    exports = RuntimeProxy.remote_exports()
    assert "export HTTP_PROXY='http://proxy.example.test:8080'" in exports
    assert Enum.any?(exports, &String.contains?(&1, "'\"'\"'"))
  end

  test "connect options use scheme defaults and proxy authentication" do
    System.put_env("HTTPS_PROXY", "https://user:pass@secure-proxy.example.test")
    System.put_env("HTTP_PROXY", "http://plain-proxy.example.test")

    https_options = RuntimeProxy.connect_options("https://api.example.test", timeout: 5)
    assert Keyword.fetch!(https_options, :timeout) == 5
    assert Keyword.fetch!(https_options, :proxy) == {:https, "secure-proxy.example.test", 443, []}
    assert [{"proxy-authorization", encoded_auth}] = Keyword.fetch!(https_options, :proxy_headers)
    assert Base.decode64!(String.trim_leading(encoded_auth, "Basic ")) == "user:pass"

    assert RuntimeProxy.connect_options("http://api.example.test") == [
             proxy: {:http, "plain-proxy.example.test", 80, []}
           ]
  end

  test "connect options ignore invalid proxy configuration" do
    System.put_env("HTTPS_PROXY", "socks5://proxy.example.test:1080")
    assert RuntimeProxy.connect_options("https://api.example.test", timeout: 5) == [timeout: 5]

    System.put_env("HTTPS_PROXY", "http://")
    assert RuntimeProxy.connect_options("https://api.example.test", timeout: 5) == [timeout: 5]
  end

  test "all proxy applies to unknown schemes and no proxy supports wildcard suffixes and ports" do
    System.put_env("ALL_PROXY", "http://proxy.example.test:8080")

    assert RuntimeProxy.connect_options("ws://socket.example.test") == [
             proxy: {:http, "proxy.example.test", 8080, []}
           ]

    System.put_env("NO_PROXY", "*.ignored")
    refute RuntimeProxy.connect_options("https://api.example.test") == []

    System.put_env("NO_PROXY", "*")
    assert RuntimeProxy.connect_options("https://api.example.test") == []

    System.put_env("NO_PROXY", ".example.test:443")
    assert RuntimeProxy.connect_options("https://api.example.test") == []

    System.put_env("NO_PROXY", "[::1]:8080")
    refute RuntimeProxy.connect_options("https://api.example.test") == []
  end

  test "redacted proxy env leaves public proxies unchanged" do
    System.put_env("HTTP_PROXY", "http://proxy.example.test:8080")

    assert RuntimeProxy.redacted_proxy_env() == %{
             "HTTP_PROXY" => "http://proxy.example.test:8080"
           }
  end
end

defmodule SymphonyElixirWeb.ProxyHeaders do
  @moduledoc """
  Runtime-controlled forwarded header support for reverse proxy deployments.

  Forwarded headers are ignored unless explicitly enabled through application
  config or environment. This keeps direct local clients from spoofing the
  externally visible scheme, host, port, or path prefix by default.
  """

  import Plug.Conn

  @truthy ~w(1 true TRUE yes YES on ON)

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if trusted?() do
      conn
      |> rewrite_scheme()
      |> rewrite_host()
      |> rewrite_port()
      |> rewrite_prefix()
      |> put_private(:symphony_proxy_headers_trusted, true)
    else
      conn
      |> put_private(:symphony_proxy_headers_trusted, false)
      |> maybe_apply_public_url()
    end
  end

  @spec trusted?() :: boolean()
  def trusted? do
    config = Application.get_env(:symphony_elixir, :proxy, [])
    Keyword.get(config, :trust_x_forwarded_headers, false) || System.get_env("SYMPHONY_TRUST_X_FORWARDED_HEADERS") in @truthy
  end

  @spec public_url() :: URI.t() | nil
  def public_url do
    value =
      Application.get_env(:symphony_elixir, :proxy, [])
      |> Keyword.get(:public_url)
      |> case do
        nil -> System.get_env("SYMPHONY_PUBLIC_URL")
        configured -> configured
      end

    case URI.new(to_string(value || "")) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(scheme) and is_binary(host) -> uri
      _ -> nil
    end
  end

  @spec external_url(Plug.Conn.t(), String.t()) :: String.t()
  def external_url(conn, path \\ "/") do
    script_name = conn.script_name || []
    prefix = if script_name == [], do: "", else: "/" <> Enum.join(script_name, "/")
    path = normalize_path(path)
    port = external_port(conn)

    %URI{
      scheme: Atom.to_string(conn.scheme),
      host: conn.host,
      port: port,
      path: prefix <> path
    }
    |> URI.to_string()
  end

  defp maybe_apply_public_url(conn) do
    case public_url() do
      %URI{} = uri ->
        conn
        |> Map.put(:scheme, uri_scheme(uri.scheme))
        |> Map.put(:host, uri.host)
        |> Map.put(:port, uri.port || default_port(uri.scheme))
        |> Map.put(:script_name, prefix_segments(uri.path))

      nil ->
        conn
    end
  end

  defp rewrite_scheme(conn) do
    case first_header(conn, "x-forwarded-proto") do
      "https" -> Map.put(conn, :scheme, :https)
      "http" -> Map.put(conn, :scheme, :http)
      _other -> conn
    end
  end

  defp rewrite_host(conn) do
    case first_header(conn, "x-forwarded-host") || first_header(conn, "host") do
      host when is_binary(host) and host != "" ->
        {hostname, port} = split_host_port(host)
        conn = Map.put(conn, :host, hostname)
        if port, do: Map.put(conn, :port, port), else: conn

      _other ->
        conn
    end
  end

  defp rewrite_port(conn) do
    case first_header(conn, "x-forwarded-port") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {port, ""} when port > 0 -> Map.put(conn, :port, port)
          _ -> conn
        end

      _other ->
        conn
    end
  end

  defp rewrite_prefix(conn) do
    conn
    |> first_header("x-forwarded-prefix")
    |> case do
      prefix when is_binary(prefix) -> Map.put(conn, :script_name, prefix_segments(prefix))
      _other -> conn
    end
  end

  defp first_header(conn, header) do
    conn
    |> get_req_header(header)
    |> List.first()
    |> case do
      nil -> nil
      value -> value |> String.split(",") |> List.first() |> String.trim()
    end
  end

  defp split_host_port(host) do
    case String.split(host, ":", parts: 2) do
      [hostname, port] ->
        case Integer.parse(port) do
          {parsed, ""} when parsed > 0 -> {hostname, parsed}
          _ -> {hostname, nil}
        end

      [hostname] ->
        {hostname, nil}
    end
  end

  defp prefix_segments(nil), do: []
  defp prefix_segments(""), do: []

  defp prefix_segments(path) do
    path
    |> String.trim()
    |> String.trim("/")
    |> case do
      "" -> []
      trimmed -> String.split(trimmed, "/", trim: true)
    end
  end

  defp normalize_path(path) when is_binary(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp normalize_path(_path), do: "/"

  defp external_port(%{scheme: :https, port: 443}), do: nil
  defp external_port(%{scheme: :http, port: 80}), do: nil
  defp external_port(%{port: port}) when is_integer(port), do: port
  defp external_port(_conn), do: nil

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80

  defp uri_scheme("https"), do: :https
  defp uri_scheme(_scheme), do: :http
end

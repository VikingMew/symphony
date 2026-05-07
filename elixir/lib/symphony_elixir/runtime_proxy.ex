defmodule SymphonyElixir.RuntimeProxy do
  @moduledoc false

  @proxy_env_names ~w(HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy)

  @spec proxy_env_names() :: [String.t()]
  def proxy_env_names, do: @proxy_env_names

  @spec proxy_env() :: [{String.t(), String.t()}]
  def proxy_env do
    @proxy_env_names
    |> Enum.flat_map(&proxy_env_entry/1)
  end

  @spec port_env() :: [{charlist(), charlist()}]
  def port_env do
    Enum.map(proxy_env(), fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  @spec remote_exports() :: [String.t()]
  def remote_exports do
    Enum.map(proxy_env(), fn {name, value} ->
      "export #{name}=#{shell_escape(value)}"
    end)
  end

  @spec connect_options(String.t(), keyword()) :: keyword()
  def connect_options(url, base_options \\ []) when is_binary(url) and is_list(base_options) do
    uri = URI.parse(url)

    if no_proxy?(uri) do
      base_options
    else
      case proxy_for_scheme(uri.scheme) do
        {:ok, nil} ->
          base_options

        {:ok, proxy_options} ->
          Keyword.merge(base_options, proxy_options)

        {:error, _reason} ->
          base_options
      end
    end
  end

  @spec redacted_proxy_env() :: map()
  def redacted_proxy_env do
    proxy_env()
    |> Map.new(fn {name, value} -> {name, redact_proxy_value(value)} end)
  end

  defp proxy_for_scheme("https") do
    ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
    |> first_proxy_value()
    |> proxy_options()
  end

  defp proxy_for_scheme("http") do
    ["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
    |> first_proxy_value()
    |> proxy_options()
  end

  defp proxy_for_scheme(_scheme) do
    ["ALL_PROXY", "all_proxy"]
    |> first_proxy_value()
    |> proxy_options()
  end

  defp first_proxy_value(names) do
    Enum.find_value(names, &non_empty_env_value/1)
  end

  defp proxy_env_entry(name) do
    case non_empty_env_value(name) do
      nil -> []
      value -> [{name, value}]
    end
  end

  defp non_empty_env_value(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp proxy_options(nil), do: {:ok, nil}

  defp proxy_options(proxy_url) when is_binary(proxy_url) do
    uri = URI.parse(proxy_url)

    with {:ok, scheme} <- proxy_scheme(uri.scheme),
         {:ok, host} <- proxy_host(uri.host),
         {:ok, port} <- proxy_port(uri) do
      options = [proxy: {scheme, host, port, []}]

      case proxy_auth_header(uri.userinfo) do
        nil -> {:ok, options}
        header -> {:ok, Keyword.put(options, :proxy_headers, [header])}
      end
    end
  end

  defp proxy_scheme("http"), do: {:ok, :http}
  defp proxy_scheme("https"), do: {:ok, :https}
  defp proxy_scheme(other), do: {:error, {:unsupported_proxy_scheme, other}}

  defp proxy_host(host) when is_binary(host) and host != "", do: {:ok, host}
  defp proxy_host(_host), do: {:error, :missing_proxy_host}

  defp proxy_port(%URI{port: port}) when is_integer(port), do: {:ok, port}
  defp proxy_port(%URI{scheme: "https"}), do: {:ok, 443}
  defp proxy_port(%URI{scheme: "http"}), do: {:ok, 80}
  defp proxy_port(_uri), do: {:error, :missing_proxy_port}

  defp proxy_auth_header(nil), do: nil
  defp proxy_auth_header(""), do: nil
  defp proxy_auth_header(userinfo), do: {"proxy-authorization", "Basic " <> Base.encode64(userinfo)}

  defp no_proxy?(%URI{host: host}) when is_binary(host) do
    no_proxy_values()
    |> Enum.any?(&no_proxy_match?(&1, host))
  end

  defp no_proxy?(_uri), do: false

  defp no_proxy_values do
    ["NO_PROXY", "no_proxy"]
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        value when is_binary(value) ->
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        _ ->
          []
      end
    end)
  end

  defp no_proxy_match?("*", _host), do: true

  defp no_proxy_match?(entry, host) do
    normalized_entry =
      entry
      |> String.downcase()
      |> String.trim_leading(".")
      |> strip_port()

    normalized_host = String.downcase(host)

    normalized_host == normalized_entry or String.ends_with?(normalized_host, "." <> normalized_entry)
  end

  defp strip_port(entry) do
    case String.split(entry, ":", parts: 2) do
      [host, port] when port != "" ->
        if String.contains?(host, "]"), do: entry, else: host

      _ ->
        entry
    end
  end

  defp redact_proxy_value(value) when is_binary(value) do
    value
    |> URI.parse()
    |> case do
      %URI{userinfo: nil} -> value
      %URI{userinfo: userinfo} -> String.replace(value, userinfo <> "@", "[REDACTED]@", global: false)
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end

defmodule SymphonyElixir.TestSupport.OutboundHTTPGuard do
  @moduledoc false

  def request(req, finch_req, name, options) do
    case get_in(req.options, [:connect_options, :proxy]) do
      nil -> :ok
      {_scheme, host, _port, _options} -> ensure_loopback!(host)
    end

    ensure_loopback!(finch_req.host)

    case Finch.request(finch_req, name, options) do
      {:ok, response} ->
        {req, Req.Response.new(status: response.status, headers: response.headers, body: response.body)}

      {:error, exception} ->
        {req, exception}
    end
  end

  defp ensure_loopback!(host) do
    if host in ["127.0.0.1", "::1"] do
      :ok
    else
      raise "violation=external_http actual=#{inspect(host)} expected=literal_loopback log_path=ExUnit"
    end
  end
end

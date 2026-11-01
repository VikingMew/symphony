defmodule SymphonyElixir.Linear.FailurePayload do
  @moduledoc false

  @inspect_options [limit: 20, printable_limit: 500]

  @spec base(term()) :: map()
  def base({:linear_api_status, status, _body}) when is_integer(status),
    do: %{"status" => status, "reason" => "http_status"}

  def base({:linear_api_request, reason}),
    do: %{"reason" => "transport:" <> transport_reason(reason)}

  def base(reason), do: %{"reason" => inspect_reason(reason)}

  defp transport_reason(%Req.TransportError{reason: reason}),
    do: transport_reason(reason)

  defp transport_reason(reason) when reason in [:closed, :timeout],
    do: Atom.to_string(reason)

  defp transport_reason(reason), do: inspect_reason(reason)

  defp inspect_reason(reason), do: inspect(reason, @inspect_options)
end

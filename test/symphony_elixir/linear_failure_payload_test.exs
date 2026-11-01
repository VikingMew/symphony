defmodule SymphonyElixir.LinearFailurePayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.FailurePayload

  test "preserves the HTTP status payload" do
    assert FailurePayload.base({:linear_api_status, 429, "limited"}) == %{
             "status" => 429,
             "reason" => "http_status"
           }
  end

  test "formats the supported transport reason shapes" do
    assert FailurePayload.base({:linear_api_request, %Req.TransportError{reason: :closed}}) == %{
             "reason" => "transport:closed"
           }

    assert FailurePayload.base({:linear_api_request, %Req.TransportError{reason: :timeout}}) == %{
             "reason" => "transport:timeout"
           }

    assert FailurePayload.base({:linear_api_request, :timeout}) == %{
             "reason" => "transport:timeout"
           }
  end

  test "uses the existing inspect limits for other transport and generic terms" do
    unknown = {:unexpected, Enum.to_list(1..100)}
    inspected = "{:unexpected, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, ...]}"

    assert FailurePayload.base({:linear_api_request, unknown}) == %{
             "reason" => "transport:" <> inspected
           }

    assert FailurePayload.base(unknown) == %{"reason" => inspected}

    long_string = String.duplicate("a", 510)

    assert FailurePayload.base({:linear_api_request, long_string}) == %{
             "reason" => "transport:" <> inspect(long_string, limit: 20, printable_limit: 500)
           }
  end

  test "keeps an unwrapped transport error on the generic branch" do
    reason = %Req.TransportError{reason: :closed}
    assert FailurePayload.base(reason) == %{"reason" => inspect(reason, limit: 20, printable_limit: 500)}
  end
end

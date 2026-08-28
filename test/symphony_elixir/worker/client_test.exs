defmodule SymphonyElixir.Worker.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Client

  test "uses the landed worker-v1 protocol identifier" do
    assert Client.protocol_version() == "worker-api-v1"
  end
end

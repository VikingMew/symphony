defmodule SymphonyElixir.PayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Payload

  test "returns explicit false from an atom-keyed map" do
    assert Payload.get_any(%{enabled: false}, [:enabled, "enabled"], true) == false
  end

  test "returns explicit false from a string-keyed map" do
    assert Payload.get_any(%{"enabled" => false}, [:enabled, "enabled"], true) == false
  end

  test "returns explicit nil instead of the default" do
    assert Payload.get_any(%{enabled: nil}, [:enabled, "enabled"], true) == nil
  end
end

defmodule SymphonyElixir.ListeningOffScriptTest do
  use ExUnit.Case, async: true

  test "repository listening-off command posts the idempotent off control" do
    script = File.read!("scripts/listening-off.sh")

    assert script =~ "/api/v1/control/listening"
    assert script =~ ~s(--data '{"mode":"off"}')
    assert script =~ ~s(echo "not_listening")

    assert {_output, 0} = System.cmd("bash", ["-n", "scripts/listening-off.sh"])
  end
end

defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport

  test "workspace/config smoke test support starts with an active workflow" do
    assert %SymphonyElixir.Config.Schema{} = Config.settings!()
  end
end

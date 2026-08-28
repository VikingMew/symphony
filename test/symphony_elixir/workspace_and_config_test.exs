defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport

  test "workspace/config smoke test support starts with a current workflow" do
    assert %SymphonyElixir.Config.Schema{} = Config.settings!()
  end
end

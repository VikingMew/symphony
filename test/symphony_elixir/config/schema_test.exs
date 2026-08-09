defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "default merge profile declares the no-push policy" do
    assert Schema.default_profiles()["merge"]["merge"] == %{
             "push" => false,
             "remote" => "origin",
             "success_state" => "Done"
           }
  end
end

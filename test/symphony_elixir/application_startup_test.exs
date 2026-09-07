defmodule SymphonyElixir.ApplicationStartupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Application, as: SymphonyApplication

  test "migration failure prevents every business child from starting" do
    parent = self()
    error = {:migration_mismatch, [{20_260_905_000_000, "move_capacity_to_deployment"}], []}

    assert SymphonyApplication.start_checked_supervisor(
             fn -> {:error, error} end,
             fn -> send(parent, :business_children_started) end
           ) == {:error, error}

    refute_received :business_children_started
  end
end

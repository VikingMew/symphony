defmodule SymphonyElixir.MigrationCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MigrationCheck

  @expected [{20_260_501_000_000, "create_symphony_persistence"}, {20_260_905_000_000, "move_capacity_to_deployment"}]

  test "accepts an exact migration set regardless of applied ordering" do
    assert MigrationCheck.compare(@expected, [20_260_905_000_000, 20_260_501_000_000]) == :ok
  end

  test "reports every pending migration with its version and name" do
    assert MigrationCheck.compare(@expected, []) ==
             {:error, {:migration_mismatch, @expected, []}}

    message = MigrationCheck.format_error({:migration_mismatch, @expected, []})
    assert message =~ "20260905000000 move_capacity_to_deployment"
  end

  test "reports every applied version unknown to the release" do
    assert MigrationCheck.compare(@expected, [20_260_501_000_000, 20_261_001_000_000, 20_261_002_000_000]) ==
             {:error, {:migration_mismatch, [{20_260_905_000_000, "move_capacity_to_deployment"}], [20_261_001_000_000, 20_261_002_000_000]}}
  end

  test "formats database and query failures as typed startup errors" do
    database_error = {:migration_check_failed, {:database_unreachable, :econnrefused}}
    query_error = {:migration_check_failed, {:migration_query, :invalid_schema}}

    assert MigrationCheck.check({:ok, @expected}, {:error, database_error}) == {:error, database_error}
    assert MigrationCheck.check({:ok, @expected}, {:error, query_error}) == {:error, query_error}

    assert MigrationCheck.format_error(database_error) =~
             "migration startup check failed"

    assert MigrationCheck.format_error(query_error) =~ "migration_query"
  end
end

defmodule SymphonyElixir.TestDatabaseIsolationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport.DatabaseIsolation

  test "accepts temporary sqlite databases only" do
    temp_root = System.tmp_dir!()
    dev_db = Path.expand("symphony.db")
    test_db = Path.join(temp_root, "symphony-elixir-test-isolation.db")

    assert :ok = DatabaseIsolation.assert_safe_test_database!(test_db, dev_db, temp_root)
  end

  test "default test suite does not start Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
  end

  test "rejects the local development database" do
    temp_root = System.tmp_dir!()
    dev_db = Path.expand("symphony.db")

    assert_raise ArgumentError, ~r/local development database/, fn ->
      DatabaseIsolation.assert_safe_test_database!(dev_db, dev_db, temp_root)
    end
  end

  test "rejects any test database named symphony db" do
    temp_root = System.tmp_dir!()
    dev_db = Path.expand("dev.db")
    bad_db = Path.join(temp_root, "symphony.db")

    assert_raise ArgumentError, ~r/database named symphony\.db/, fn ->
      DatabaseIsolation.assert_safe_test_database!(bad_db, dev_db, temp_root)
    end
  end

  test "rejects test databases outside the temporary root" do
    temp_root = System.tmp_dir!()
    dev_db = Path.join(temp_root, "dev.db")
    bad_db = Path.expand("tmp/test.db")

    assert_raise ArgumentError, ~r/Test database must be under/, fn ->
      DatabaseIsolation.assert_safe_test_database!(bad_db, dev_db, temp_root)
    end
  end
end

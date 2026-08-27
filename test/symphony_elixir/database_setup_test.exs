defmodule SymphonyElixir.DatabaseSetupTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{DatabaseSetup, Repo}

  setup do
    previous_config = Application.fetch_env!(:symphony_elixir, Repo)
    on_exit(fn -> Application.put_env(:symphony_elixir, Repo, previous_config) end)
    :ok
  end

  test "requires a non-blank DATABASE_URL contract" do
    Application.put_env(:symphony_elixir, Repo, pool_size: 5)
    assert DatabaseSetup.validate_config() == {:error, :missing_database_url}

    Application.put_env(:symphony_elixir, Repo, url: "  ", pool_size: 5)
    assert DatabaseSetup.validate_config() == {:error, :missing_database_url}

    Application.put_env(:symphony_elixir, Repo, url: "postgresql://localhost/symphony", pool_size: 5)
    assert DatabaseSetup.validate_config() == :ok
  end

  test "formats database configuration and connectivity failures explicitly" do
    assert DatabaseSetup.format_error(:missing_database_url) == "DATABASE_URL is required"
    assert DatabaseSetup.format_error({:database_unreachable, :econnrefused}) =~ "PostgreSQL is unreachable"
    assert DatabaseSetup.format_error({:migration_failed, :invalid_schema}) =~ "PostgreSQL migration failed"
  end
end

defmodule SymphonyElixir.TestSupport.DatabaseIsolation do
  @moduledoc false

  @spec assert_safe_test_database!(Path.t(), Path.t(), Path.t()) :: :ok
  def assert_safe_test_database!(repo_database, dev_database, temp_root) do
    repo_database = Path.expand(repo_database)
    dev_database = Path.expand(dev_database)
    temp_root = Path.expand(temp_root)

    cond do
      repo_database == dev_database ->
        raise ArgumentError, "Refusing to run tests against local development database: #{repo_database}"

      Path.basename(repo_database) == "symphony.db" ->
        raise ArgumentError, "Refusing to run tests against a database named symphony.db: #{repo_database}"

      not under_path?(repo_database, temp_root) ->
        raise ArgumentError, "Test database must be under #{temp_root}, got: #{repo_database}"

      true ->
        :ok
    end
  end

  @spec cleanup_sqlite_files(Path.t()) :: :ok
  def cleanup_sqlite_files(database) do
    File.rm_rf(database)
    File.rm_rf(database <> "-shm")
    File.rm_rf(database <> "-wal")
    :ok
  end

  defp under_path?(path, root) do
    relative = Path.relative_to(path, root)
    relative != path and not String.starts_with?(relative, "..")
  end
end

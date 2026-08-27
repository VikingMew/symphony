defmodule Mix.Tasks.Symphony.SqliteImport do
  @moduledoc """
  Imports a stopped legacy SQLite backup into empty, migrated PostgreSQL.
  """

  use Mix.Task

  @shortdoc "Imports a legacy symphony.db backup into PostgreSQL"
  @requirements ["app.config"]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    case OptionParser.parse(args, strict: [source: :string]) do
      {[source: source], [], []} when source != "" -> run_import(source)
      _ -> Mix.raise("Usage: mix symphony.sqlite_import --source /path/to/symphony.backup.db")
    end
  end

  defp run_import(source) do
    case SymphonyElixir.Release.import_sqlite(source) do
      {:ok, counts} ->
        Enum.each(SymphonyElixir.SQLiteImporter.app_tables(), fn table ->
          Mix.shell().info("verified table=#{table} rows=#{Map.fetch!(counts, table)}")
        end)

        :ok

      {:error, reason} ->
        Mix.raise("SQLite import failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}")
    end
  end
end

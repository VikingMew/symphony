defmodule SymphonyElixir.Release do
  @moduledoc """
  Release-safe database maintenance entrypoints.
  """

  alias SymphonyElixir.{DatabaseSetup, Repo, SQLiteImporter}

  @spec migrate() :: :ok | {:error, term()}
  def migrate do
    with :ok <- load_application() do
      DatabaseSetup.prepare()
    end
  end

  @spec migrate!() :: :ok
  def migrate! do
    case migrate() do
      :ok -> :ok
      {:error, reason} -> raise DatabaseSetup.format_error(reason)
    end
  end

  @spec import_sqlite(Path.t()) :: {:ok, SQLiteImporter.counts()} | {:error, term()}
  def import_sqlite(source_path) when is_binary(source_path) do
    with :ok <- load_application(),
         :ok <- DatabaseSetup.prepare() do
      Ecto.Migrator.with_repo(Repo, fn repo -> SQLiteImporter.import_backup(repo, source_path) end)
      |> case do
        {:ok, result, _apps} -> result
        {:error, reason} -> {:error, {:database_unreachable, reason}}
      end
    end
  end

  @spec import_sqlite!() :: SQLiteImporter.counts()
  def import_sqlite! do
    source_path = System.fetch_env!("SQLITE_BACKUP_PATH")

    case import_sqlite(source_path) do
      {:ok, counts} ->
        Enum.each(SQLiteImporter.app_tables(), fn table ->
          IO.puts("verified table=#{table} rows=#{Map.fetch!(counts, table)}")
        end)

        counts

      {:error, reason} ->
        raise "SQLite import failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"
    end
  end

  defp load_application do
    case Application.load(:symphony_elixir) do
      :ok -> :ok
      {:error, {:already_loaded, :symphony_elixir}} -> :ok
      {:error, reason} -> {:error, {:application_load_failed, reason}}
    end
  end
end

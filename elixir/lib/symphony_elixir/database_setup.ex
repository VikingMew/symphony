defmodule SymphonyElixir.DatabaseSetup do
  @moduledoc """
  Prepares the local SQLite database before the application supervisor starts.
  """

  alias SymphonyElixir.Repo

  @max_attempts 5
  @retry_sleep_ms 200

  @spec prepare() :: :ok | {:error, term()}
  def prepare do
    with :ok <- ensure_database_directory(),
         :ok <- retry_locked(&create_storage/0) do
      retry_locked(&run_migrations/0)
    end
  end

  defp ensure_database_directory do
    case Keyword.fetch(Repo.config(), :database) do
      {:ok, database} when is_binary(database) and database not in [":memory:", ""] ->
        database
        |> Path.dirname()
        |> File.mkdir_p()

      _ ->
        :ok
    end
  end

  defp create_storage do
    case Repo.__adapter__().storage_up(Repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end
  end

  defp run_migrations do
    Ecto.Migrator.with_repo(Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_path(), :up, all: true)
    end)
    |> case do
      {:ok, _migrations, _apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrations_path do
    :symphony_elixir
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("repo/migrations")
  end

  defp retry_locked(fun), do: retry_locked(fun, 1)

  defp retry_locked(fun, attempt) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} = error ->
        if database_locked?(reason) and attempt < @max_attempts do
          Process.sleep(@retry_sleep_ms * attempt)
          retry_locked(fun, attempt + 1)
        else
          error
        end
    end
  end

  defp database_locked?(%Exqlite.Error{message: message}), do: String.contains?(message, "database is locked")
  defp database_locked?(%{message: message}) when is_binary(message), do: String.contains?(message, "database is locked")
  defp database_locked?(reason) when is_binary(reason), do: String.contains?(reason, "database is locked")
  defp database_locked?(_reason), do: false
end

defmodule SymphonyElixir.MigrationCheck do
  @moduledoc """
  Verifies that the release migrations exactly match PostgreSQL migration state.

  This startup check is deliberately read-only. Production schema changes remain
  the responsibility of the release migration command.
  """

  require Logger

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Repo

  @type migration :: {non_neg_integer(), String.t()}
  @type mismatch :: {:migration_mismatch, [migration()], [non_neg_integer()]}
  @type error :: mismatch() | {:migration_check_failed, term()}

  @spec check() :: :ok | {:error, error()}
  def check do
    check(embedded_migrations(), applied_versions())
  end

  @doc false
  @spec check({:ok, [migration()]} | {:error, error()}, {:ok, [non_neg_integer()]} | {:error, error()}) ::
          :ok | {:error, error()}
  def check(expected_result, applied_result) do
    with {:ok, expected} <- expected_result,
         {:ok, applied} <- applied_result,
         :ok <- compare(expected, applied) do
      Logger.info("Migration startup check status=current expected_versions=#{inspect(versions(expected))} applied_versions=#{inspect(applied)}")

      :ok
    else
      {:error, {:migration_mismatch, pending, unknown} = reason} ->
        Logger.error("Migration startup check status=mismatch pending_migrations=#{format_pending(pending)} unknown_applied_versions=#{format_versions(unknown)}")

        {:error, reason}

      {:error, {:migration_check_failed, detail} = reason} ->
        Logger.error("Migration startup check status=failed reason=#{inspect(detail)}")
        {:error, reason}
    end
  end

  @spec compare([migration()], [non_neg_integer()]) :: :ok | {:error, mismatch()}
  def compare(expected, applied) do
    applied_set = MapSet.new(applied)
    expected_versions = expected |> versions() |> MapSet.new()

    pending = Enum.reject(expected, fn {version, _name} -> MapSet.member?(applied_set, version) end)
    unknown = Enum.reject(applied, &MapSet.member?(expected_versions, &1))

    case {pending, unknown} do
      {[], []} -> :ok
      _mismatch -> {:error, {:migration_mismatch, pending, unknown}}
    end
  end

  @spec format_error(error()) :: String.t()
  def format_error({:migration_mismatch, pending, unknown}) do
    "PostgreSQL migration mismatch: pending migrations=#{format_pending(pending)}; " <>
      "unknown applied versions=#{format_versions(unknown)}"
  end

  def format_error({:migration_check_failed, reason}) do
    "PostgreSQL migration startup check failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"
  end

  defp embedded_migrations do
    case File.ls(migrations_path()) do
      {:ok, files} -> {:ok, files |> Enum.flat_map(&parse_migration/1) |> Enum.sort()}
      {:error, reason} -> {:error, {:migration_check_failed, {:embedded_migrations, reason}}}
    end
  end

  defp applied_versions do
    Ecto.Migrator.with_repo(Repo, fn repo ->
      SQL.query(repo, "SELECT version FROM schema_migrations ORDER BY version", [])
    end)
    |> case do
      {:ok, {:ok, %{rows: rows}}, _apps} -> {:ok, Enum.map(rows, fn [version] -> version end)}
      {:ok, {:error, reason}, _apps} -> {:error, {:migration_check_failed, {:migration_query, reason}}}
      {:error, reason} -> {:error, {:migration_check_failed, {:database_unreachable, reason}}}
    end
  end

  defp parse_migration(file) do
    case Integer.parse(Path.rootname(file)) do
      {version, "_" <> name} -> [{version, name}]
      _not_a_migration -> []
    end
  end

  defp migrations_path do
    :symphony_elixir
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("repo/migrations")
  end

  defp versions(migrations), do: Enum.map(migrations, &elem(&1, 0))
  defp format_pending([]), do: "none"
  defp format_pending(pending), do: Enum.map_join(pending, ", ", fn {version, name} -> "#{version} #{name}" end)
  defp format_versions([]), do: "none"
  defp format_versions(versions), do: Enum.join(versions, ", ")
end

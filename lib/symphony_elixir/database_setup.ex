defmodule SymphonyElixir.DatabaseSetup do
  @moduledoc """
  Validates the PostgreSQL connection and runs migrations before Symphony starts.
  """

  alias SymphonyElixir.Repo

  @spec prepare() :: :ok | {:error, term()}
  def prepare do
    with :ok <- validate_config() do
      run_migrations()
    end
  end

  @spec validate_config() :: :ok | {:error, :missing_database_url}
  def validate_config do
    case :symphony_elixir |> Application.get_env(Repo, []) |> Keyword.get(:url) do
      url when is_binary(url) ->
        if String.trim(url) == "", do: {:error, :missing_database_url}, else: :ok

      _missing ->
        {:error, :missing_database_url}
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(:missing_database_url), do: "DATABASE_URL is required"

  def format_error({:database_unreachable, reason}) do
    "PostgreSQL is unreachable: #{inspect(reason, limit: 20, printable_limit: 1_000)}"
  end

  def format_error({:migration_failed, reason}) do
    "PostgreSQL migration failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"
  end

  def format_error(reason), do: inspect(reason, limit: 20, printable_limit: 1_000)

  defp run_migrations do
    Ecto.Migrator.with_repo(Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_path(), :up, all: true)
    end)
    |> case do
      {:ok, _migrations, _apps} -> :ok
      {:error, reason} -> {:error, {:database_unreachable, reason}}
    end
  rescue
    error -> {:error, {:migration_failed, error}}
  catch
    kind, reason -> {:error, {:migration_failed, {kind, reason}}}
  end

  defp migrations_path do
    :symphony_elixir
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("repo/migrations")
  end
end

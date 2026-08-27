defmodule Mix.Tasks.Symphony.Migrate do
  @moduledoc """
  Runs all pending Symphony PostgreSQL migrations.
  """

  use Mix.Task

  @shortdoc "Runs Symphony PostgreSQL migrations"
  @requirements ["app.config"]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    case SymphonyElixir.Release.migrate() do
      :ok -> Mix.shell().info("PostgreSQL migrations are current")
      {:error, reason} -> Mix.raise(SymphonyElixir.DatabaseSetup.format_error(reason))
    end
  end
end

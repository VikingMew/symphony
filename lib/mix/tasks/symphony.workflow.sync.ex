defmodule Mix.Tasks.Symphony.Workflow.Sync do
  @moduledoc """
  Synchronizes the checked-in workflow package to PostgreSQL.
  """

  use Mix.Task

  alias SymphonyElixir.{Repo, RepositoryWorkflow}

  @shortdoc "Synchronizes the repository workflow package"
  @requirements ["app.config"]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [project: :string, all: :boolean, check: :boolean])
    if rest != [] or invalid != [], do: Mix.raise(usage())

    target = target!(opts)

    result =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        if opts[:check], do: RepositoryWorkflow.check(target), else: RepositoryWorkflow.sync(target)
      end)

    case result do
      {:ok, :ok, _apps} -> Mix.shell().info("Repository workflow matches PostgreSQL")
      {:ok, {:ok, counts}, _apps} -> Mix.shell().info("Repository workflow synchronized: #{counts.changed} changed, #{counts.unchanged} unchanged")
      {:ok, {:error, reason}, _apps} -> Mix.raise(format_error(reason))
      {:error, reason} -> Mix.raise(format_error(reason))
    end
  end

  defp target!(opts) do
    case {opts[:project], opts[:all]} do
      {slug, nil} when is_binary(slug) and slug != "" -> slug
      {nil, true} -> :all
      _ -> Mix.raise(usage())
    end
  end

  defp usage, do: "expected exactly one of --project PROJECT_SLUG or --all; add --check to detect drift without writing"
  defp format_error(reason), do: "workflow synchronization failed: #{inspect(reason)}"
end

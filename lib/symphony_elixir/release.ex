defmodule SymphonyElixir.Release do
  @moduledoc """
  Release-safe database maintenance entrypoints.
  """

  alias SymphonyElixir.{DatabaseSetup, Repo, SQLiteImporter}
  alias SymphonyElixir.Persistence.WorkflowStore
  alias SymphonyElixir.Release.LegacyWorkflowCommand

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

  @spec reconcile_legacy_instance_workflow!() :: term()
  def reconcile_legacy_instance_workflow! do
    :ok = load_application()

    Ecto.Migrator.with_repo(Repo, fn _repo ->
      {:ok, status} = WorkflowStore.legacy_instance_workflow_status()

      case LegacyWorkflowCommand.execute(
             status,
             System.get_env("SYMPHONY_RECONCILE_PROJECT"),
             &WorkflowStore.reconcile_legacy_instance_workflow/1,
             &IO.puts/1
           ) do
        {:ok, result} -> result
        {:error, reason} -> raise "Legacy instance workflow reconciliation failed: #{inspect(reason)}"
      end
    end)
    |> case do
      {:ok, result, _apps} -> result
      {:error, reason} -> raise "Legacy instance workflow database startup failed: #{inspect(reason)}"
    end
  end

  @spec project_identity_status!() :: SymphonyElixir.Persistence.WorkflowStore.project_identity_status()
  def project_identity_status! do
    :ok = load_application()

    Ecto.Migrator.with_repo(Repo, fn _repo ->
      {:ok, status} = WorkflowStore.project_identity_status()
      print_project_identity_status(status)
      status
    end)
    |> unwrap_repo_result("Project identity status failed")
  end

  @spec reconcile_project_identities!() :: map()
  def reconcile_project_identities! do
    :ok = load_application()

    Ecto.Migrator.with_repo(Repo, fn _repo ->
      {:ok, result} = WorkflowStore.reconcile_project_identities()
      IO.puts("project identity reconciliation updated=#{result.updated}")
      print_project_identity_status(result.status)
      result
    end)
    |> unwrap_repo_result("Project identity reconciliation failed")
  end

  defp print_project_identity_status(status) do
    IO.puts("project identity status mismatches=#{status.mismatch_count}")

    Enum.each(status.workflows, fn workflow ->
      IO.puts("workflow: id=#{workflow.workflow_id} project_id=#{workflow.project_id} project_slug=#{workflow.project_slug}")
    end)
  end

  defp unwrap_repo_result({:ok, result, _apps}, _message), do: result
  defp unwrap_repo_result({:error, reason}, message), do: raise("#{message}: #{inspect(reason)}")

  defp load_application do
    case Application.load(:symphony_elixir) do
      :ok -> :ok
      {:error, {:already_loaded, :symphony_elixir}} -> :ok
      {:error, reason} -> {:error, {:application_load_failed, reason}}
    end
  end
end

defmodule SymphonyElixir.SQLiteImporter do
  @moduledoc """
  One-way importer from a stopped SQLite backup into an empty PostgreSQL schema.

  SQLite is accessed through the `sqlite3` command-line client and is never a
  selectable runtime Ecto backend.
  """

  alias Ecto.Adapters.SQL

  @tables [
    {"users",
     [
       id: :uuid,
       username: :text,
       password_hash: :text,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"projects",
     [
       id: :uuid,
       name: :text,
       slug: :text,
       description: :text,
       enabled: :boolean,
       linear_project_slug: :text,
       repository_url: :text,
       default_branch: :text,
       checkout_depth: :integer,
       source_strategy: :text,
       worktree_fetch: :boolean,
       worktree_cleanup: :boolean,
       after_create_hook: :text,
       before_run_hook: :text,
       after_run_hook: :text,
       before_remove_hook: :text,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"tracker_configs",
     [
       id: :uuid,
       project_id: :uuid,
       kind: :text,
       endpoint: :text,
       project_slug: :text,
       api_key_secret_ref: :text,
       active_states: :jsonb,
       terminal_states: :jsonb,
       enabled: :boolean,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"workflows",
     [
       id: :uuid,
       project_id: :uuid,
       raw_workflow_md: :text,
       yaml_config: :jsonb,
       prompt_body: :text,
       source: :text,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"issues",
     [
       id: :uuid,
       project_id: :uuid,
       tracker_issue_id: :text,
       identifier: :text,
       title: :text,
       state: :text,
       url: :text,
       labels: :jsonb,
       snapshot: :jsonb,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"runs",
     [
       id: :uuid,
       project_id: :uuid,
       issue_id: :uuid,
       issue_identifier: :text,
       workspace_path: :text,
       status: :text,
       attempt: :integer,
       failure_reason: :text,
       started_at: :timestamp,
       finished_at: :timestamp,
       inserted_at: :timestamp,
       updated_at: :timestamp,
       execution_mode: :text,
       kind: :text,
       profile: :text,
       label: :text
     ]},
    {"agent_turns",
     [
       id: :uuid,
       run_id: :uuid,
       turn_index: :integer,
       status: :text,
       summary: :text,
       started_at: :timestamp,
       finished_at: :timestamp,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"workspaces",
     [
       id: :uuid,
       project_id: :uuid,
       issue_identifier: :text,
       path: :text,
       host: :text,
       status: :text,
       created_at: :timestamp,
       cleaned_at: :timestamp,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"events",
     [
       id: :uuid,
       project_id: :uuid,
       run_id: :uuid,
       issue_identifier: :text,
       event_type: :text,
       payload: :jsonb,
       occurred_at: :timestamp,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"app_settings", [key: :text, value: :jsonb, inserted_at: :timestamp, updated_at: :timestamp]},
    {"workers",
     [
       id: :uuid,
       name: :text,
       status: :text,
       labels: :jsonb,
       capabilities: :jsonb,
       credential_ref: :text,
       last_seen_at: :timestamp,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"worker_sessions",
     [
       id: :uuid,
       worker_id: :uuid,
       protocol_version: :text,
       worker_version: :text,
       instance_id: :text,
       connected_at: :timestamp,
       last_heartbeat_at: :timestamp,
       disconnected_at: :timestamp,
       status: :text,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"tasks",
     [
       id: :uuid,
       project_id: :uuid,
       run_id: :uuid,
       issue_identifier: :text,
       status: :text,
       priority: :integer,
       execution_mode: :text,
       required_capabilities: :jsonb,
       payload: :jsonb,
       queued_at: :timestamp,
       started_at: :timestamp,
       finished_at: :timestamp,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]},
    {"task_leases",
     [
       id: :uuid,
       task_id: :uuid,
       worker_id: :uuid,
       worker_session_id: :uuid,
       status: :text,
       attempt: :integer,
       expires_at: :timestamp,
       acquired_at: :timestamp,
       released_at: :timestamp,
       inserted_at: :timestamp,
       updated_at: :timestamp
     ]}
  ]

  @type counts :: %{required(String.t()) => non_neg_integer()}

  @spec app_tables() :: [String.t()]
  def app_tables, do: Enum.map(@tables, &elem(&1, 0))

  @spec import_backup(module(), Path.t()) :: {:ok, counts()} | {:error, term()}
  def import_backup(repo, source_path) when is_atom(repo) and is_binary(source_path) do
    source_path = Path.expand(source_path)

    with {:ok, sqlite3} <- sqlite_executable(),
         :ok <- validate_source(source_path, sqlite3) do
      import_transaction(repo, source_path, sqlite3)
    end
  end

  defp sqlite_executable do
    case System.find_executable("sqlite3") do
      nil -> {:error, :sqlite3_not_found}
      executable -> {:ok, executable}
    end
  end

  defp validate_source(source_path, sqlite3) do
    cond do
      not File.regular?(source_path) ->
        {:error, {:sqlite_backup_not_found, source_path}}

      Enum.any?([source_path <> "-wal", source_path <> "-shm"], &File.exists?/1) ->
        {:error, {:sqlite_backup_has_live_sidecar, source_path}}

      true ->
        validate_quick_check(sqlite3, source_path)
    end
  end

  defp validate_quick_check(sqlite3, source_path) do
    case sqlite_raw(sqlite3, source_path, "PRAGMA quick_check") do
      {:ok, output} -> validate_quick_check_output(String.trim(output))
      {:error, reason} -> {:error, {:sqlite_quick_check_failed, reason}}
    end
  end

  defp validate_quick_check_output("ok"), do: :ok
  defp validate_quick_check_output(output), do: {:error, {:sqlite_quick_check_failed, output}}

  defp import_transaction(repo, source_path, sqlite3) do
    repo.transaction(
      fn ->
        ensure_empty_target!(repo)
        import_tables!(repo, source_path, sqlite3)
      end,
      timeout: :infinity
    )
  rescue
    error -> {:error, {:sqlite_import_failed, error}}
  catch
    kind, reason -> {:error, {:sqlite_import_failed, {kind, reason}}}
  end

  defp import_tables!(repo, source_path, sqlite3) do
    Enum.reduce(@tables, %{}, fn {table, columns}, counts ->
      rows = source_rows_for_table!(sqlite3, source_path, table, columns)
      insert_rows!(repo, table, columns, rows)
      target_count = target_count!(repo, table)
      verify_count!(repo, table, length(rows), target_count)
      Map.put(counts, table, target_count)
    end)
  end

  defp source_rows_for_table!(sqlite3, source_path, "workflows", columns) do
    source_columns =
      List.insert_at(columns, 2, {:version, :integer})
      |> List.insert_at(7, {:active, :boolean})

    sqlite3
    |> source_rows!(source_path, "workflow_versions", source_columns, "WHERE active = 1")
    |> Enum.map(&Map.drop(&1, ["version", "active"]))
  end

  defp source_rows_for_table!(sqlite3, source_path, table, columns) do
    source_rows!(sqlite3, source_path, table, columns)
  end

  defp verify_count!(_repo, _table, expected, expected), do: :ok

  defp verify_count!(repo, table, expected, actual) do
    repo.rollback({:verification_count_mismatch, table, expected, actual})
  end

  defp ensure_empty_target!(repo) do
    non_empty =
      Enum.reduce(@tables, %{}, fn {table, _columns}, counts ->
        case target_count!(repo, table) do
          0 -> counts
          count -> Map.put(counts, table, count)
        end
      end)

    if map_size(non_empty) > 0 do
      repo.rollback({:target_not_empty, non_empty})
    end
  end

  defp source_rows!(sqlite3, source_path, table, columns) do
    source_rows!(sqlite3, source_path, table, columns, "")
  end

  defp source_rows!(sqlite3, source_path, table, columns, where) do
    selected = Enum.map_join(columns, ", ", fn {column, _type} -> quote_identifier(column) end)
    sql = "SELECT #{selected} FROM #{quote_identifier(table)} #{where} ORDER BY rowid"

    case sqlite_json(sqlite3, source_path, sql) do
      {:ok, output} -> decode_rows!(table, output)
      {:error, reason} -> raise "SQLite read failed for #{table}: #{reason}"
    end
  end

  defp sqlite_raw(sqlite3, source_path, sql) do
    run_sqlite(sqlite3, ["-readonly", source_path, sql])
  end

  defp sqlite_json(sqlite3, source_path, sql) do
    run_sqlite(sqlite3, ["-readonly", "-json", source_path, sql])
  end

  defp run_sqlite(sqlite3, args) do
    case System.cmd(sqlite3, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, "exit=#{status} output=#{String.trim(output)}"}
    end
  end

  defp decode_rows!(table, output) do
    if String.trim(output) == "" do
      []
    else
      case Jason.decode(output) do
        {:ok, rows} when is_list(rows) -> rows
        {:ok, other} -> raise "SQLite query for #{table} returned #{inspect(other)} instead of rows"
        {:error, reason} -> raise "SQLite JSON decode failed for #{table}: #{Exception.message(reason)}"
      end
    end
  end

  defp insert_rows!(_repo, _table, _columns, []), do: :ok

  defp insert_rows!(repo, table, columns, rows) do
    Enum.each(Enum.chunk_every(rows, 250), fn batch ->
      {values_sql, params} = batch_values(columns, batch)
      column_sql = Enum.map_join(columns, ", ", fn {column, _type} -> quote_identifier(column) end)
      sql = "INSERT INTO #{quote_identifier(table)} (#{column_sql}) VALUES #{values_sql}"
      SQL.query!(repo, sql, params, timeout: :infinity)
    end)
  end

  defp batch_values(columns, rows) do
    {row_sql, params, _next_index} =
      Enum.reduce(rows, {[], [], 1}, fn row, {sql_rows, params, index} ->
        {placeholders, row_params, next_index} = row_values(columns, row, index)
        {["(" <> Enum.join(placeholders, ", ") <> ")" | sql_rows], params ++ row_params, next_index}
      end)

    {row_sql |> Enum.reverse() |> Enum.join(", "), params}
  end

  defp row_values(columns, row, start_index) do
    Enum.reduce(columns, {[], [], start_index}, fn {column, type}, {placeholders, params, index} ->
      value = row |> Map.get(Atom.to_string(column)) |> normalize_value(type)
      placeholder = "$#{index}::#{postgres_type(type)}"
      {[placeholder | placeholders], params ++ [value], index + 1}
    end)
    |> then(fn {placeholders, params, index} -> {Enum.reverse(placeholders), params, index} end)
  end

  defp normalize_value(nil, _type), do: nil
  defp normalize_value(0, :boolean), do: false
  defp normalize_value(1, :boolean), do: true
  defp normalize_value(value, :boolean) when is_boolean(value), do: value

  defp normalize_value(value, :uuid) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, uuid} -> uuid
      :error -> raise "Invalid UUID value in SQLite source: #{inspect(value)}"
    end
  end

  defp normalize_value(value, :jsonb) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise "Invalid JSON value in SQLite source: #{Exception.message(reason)}"
    end
  end

  defp normalize_value(value, :timestamp) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_naive(datetime)
      {:error, _reason} -> parse_naive_datetime!(value)
    end
  end

  defp normalize_value(value, _type), do: value

  defp parse_naive_datetime!(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> datetime
      {:error, reason} -> raise "Invalid timestamp value in SQLite source: #{inspect(value)} (#{reason})"
    end
  end

  defp postgres_type(:uuid), do: "uuid"
  defp postgres_type(:text), do: "text"
  defp postgres_type(:integer), do: "integer"
  defp postgres_type(:boolean), do: "boolean"
  defp postgres_type(:jsonb), do: "jsonb"
  defp postgres_type(:timestamp), do: "timestamp"

  defp target_count!(repo, table) do
    %{rows: [[count]]} = SQL.query!(repo, "SELECT COUNT(*) FROM #{quote_identifier(table)}", [])
    count
  end

  defp quote_identifier(identifier) when is_atom(identifier), do: quote_identifier(Atom.to_string(identifier))
  defp quote_identifier(identifier) when is_binary(identifier), do: ~s("#{identifier}")
end

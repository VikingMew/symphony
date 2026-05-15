defmodule SymphonyElixir.CLI do
  @moduledoc """
  Command-line entrypoint for running Symphony.
  """

  alias SymphonyElixir.LogFile

  @switches [database_path: :string, logs_root: :string, port: :integer]
  @runtime_apps [
    :logger,
    :crypto,
    :bandit,
    :phoenix,
    :phoenix_html,
    :phoenix_live_view,
    :req,
    :jason,
    :yaml_elixir,
    :solid,
    :ecto,
    :ecto_sql,
    :ecto_sqlite3
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          set_database_path: (String.t() -> :ok | {:error, term()}),
          set_workflow_source: (atom() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_database_path(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run_default(opts, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run_default(keyword(), deps()) :: :ok | {:error, String.t()}
  def run_default(_opts, deps) do
    :ok = deps.set_workflow_source.(:database)
    start_database(deps)
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      set_database_path: &set_database_path/1,
      set_workflow_source: &set_workflow_source/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: &start_runtime_application/0
    }
  end

  defp start_runtime_application do
    with {:ok, started_apps} <- start_runtime_dependencies(),
         :ok <- SymphonyElixir.DatabaseSetup.prepare(),
         {:ok, _pid} <- start_symphony_supervisor() do
      {:ok, started_apps ++ [:symphony_elixir]}
    end
  end

  defp start_runtime_dependencies do
    Enum.reduce_while(@runtime_apps, {:ok, []}, fn app, {:ok, acc} ->
      case Application.ensure_all_started(app) do
        {:ok, apps} -> {:cont, {:ok, Enum.uniq(acc ++ apps)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_symphony_supervisor do
    case SymphonyElixir.Application.start(:normal, []) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_database_path(opts, deps) do
    case Keyword.get_values(opts, :database_path) do
      [] ->
        :ok

      values ->
        database_path = values |> List.last() |> String.trim()

        if database_path == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_database_path.(Path.expand(database_path))
        end
    end
  end

  defp set_database_path(database_path) do
    config = Application.get_env(:symphony_elixir, SymphonyElixir.Repo, [])
    Application.put_env(:symphony_elixir, SymphonyElixir.Repo, Keyword.put(config, :database, database_path))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp set_workflow_source(:database) do
    Application.put_env(:symphony_elixir, :workflow_source, :database)
    :ok
  end

  defp set_workflow_source(_source) do
    {:error, :unsupported_workflow_source}
  end

  defp start_database(deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony: #{inspect(reason)}"}
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal ->
                System.halt(0)

              _ ->
                IO.puts(:stderr, "Symphony supervisor stopped: #{inspect(reason)}")
                System.halt(1)
            end
        end
    end
  end
end

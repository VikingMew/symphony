defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @removed_ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "defaults to database workflow source when no args are provided" do
    parent = self()

    deps = deps(parent)

    assert :ok = CLI.evaluate([], deps)
    assert_received {:workflow_source, :database}
    assert_received :started
  end

  test "accepts --port and selects database workflow source" do
    parent = self()

    deps = deps(parent)

    assert :ok = CLI.evaluate(["--port", "4000"], deps)
    assert_received {:port, 4000}
    assert_received {:workflow_source, :database}
    assert_received :started
  end

  test "accepts --database-path and passes an expanded path to runtime deps" do
    parent = self()
    database_path = "tmp/custom-symphony.db"

    deps = deps(parent)

    assert :ok = CLI.evaluate(["--database-path", database_path], deps)
    assert_received {:database_path, expanded_path}
    assert expanded_path == Path.expand(database_path)
    assert_received {:workflow_source, :database}
    assert_received :started
  end

  test "accepts --logs-root and --database-path together" do
    parent = self()

    deps = deps(parent)

    assert :ok =
             CLI.evaluate(
               ["--logs-root", "tmp/custom-logs", "--database-path", "tmp/custom-symphony.db"],
               deps
             )

    assert_received {:logs_root, logs_root}
    assert logs_root == Path.expand("tmp/custom-logs")
    assert_received {:database_path, database_path}
    assert database_path == Path.expand("tmp/custom-symphony.db")
    assert_received {:workflow_source, :database}
    assert_received :started
  end

  test "rejects positional workflow path arguments" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["workflow.yml"], deps)
    assert message == "Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]"
  end

  test "rejects positional workflow path arguments with --port" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--port", "4000", "workflow.yml"], deps)
    assert message == "Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]"
  end

  test "rejects the removed acknowledgement flag as invalid usage" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate([@removed_ack_flag], deps)
    assert message == "Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]"
  end

  test "rejects blank --database-path" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--database-path", ""], deps)
    assert message == "Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]"
  end

  test "rejects blank --logs-root" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--logs-root", ""], deps)
    assert message == "Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]"
  end

  test "rejects invalid --port" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--port", "-1"], deps)
    assert message == "Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]"
  end

  test "returns startup error when app cannot start" do
    deps =
      deps(self(),
        ensure_all_started: fn ->
          {:error, :boom}
        end
      )

    assert {:error, message} = CLI.evaluate([], deps)
    assert message =~ "Failed to start Symphony"
    assert message =~ ":boom"
  end

  defp deps(parent, overrides \\ []) do
    defaults = %{
      set_database_path: fn path ->
        send(parent, {:database_path, path})
        :ok
      end,
      set_workflow_source: fn source ->
        send(parent, {:workflow_source, source})
        :ok
      end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port, port})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    Enum.into(overrides, defaults)
  end
end

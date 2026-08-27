defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CLI

  @removed_ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "starts with no args" do
    parent = self()

    deps = deps(parent)

    assert :ok = CLI.evaluate([], deps)
    assert_received :started
  end

  test "accepts --port" do
    parent = self()

    deps = deps(parent)

    assert :ok = CLI.evaluate(["--port", "4000"], deps)
    assert_received {:port, 4000}
    assert_received :started
  end

  test "accepts --logs-root" do
    parent = self()

    deps = deps(parent)

    assert :ok =
             CLI.evaluate(
               ["--logs-root", "tmp/custom-logs"],
               deps
             )

    assert_received {:logs_root, logs_root}
    assert logs_root == Path.expand("tmp/custom-logs")
    assert_received :started
  end

  test "rejects positional workflow path arguments" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["workflow.yml"], deps)
    assert message == usage_message()
  end

  test "rejects positional workflow path arguments with --port" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--port", "4000", "workflow.yml"], deps)
    assert message == usage_message()
  end

  test "rejects the removed acknowledgement flag as invalid usage" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate([@removed_ack_flag], deps)
    assert message == usage_message()
  end

  test "rejects removed --database-path" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--database-path", "tmp/symphony.db"], deps)
    assert message == usage_message()
  end

  test "rejects blank --logs-root" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--logs-root", ""], deps)
    assert message == usage_message()
  end

  test "rejects invalid --port" do
    deps = deps(self())

    assert {:error, message} = CLI.evaluate(["--port", "-1"], deps)
    assert message == usage_message()
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

  test "accepts --no-default-yaml-prompt" do
    deps = deps(self())

    assert :ok = CLI.evaluate(["--no-default-yaml-prompt"], deps)
    assert Application.get_env(:symphony_elixir, :no_default_yaml_prompt) == true
    assert_received :started
  end

  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [--no-default-yaml-prompt]"
  end

  defp deps(parent, overrides \\ []) do
    defaults = %{
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

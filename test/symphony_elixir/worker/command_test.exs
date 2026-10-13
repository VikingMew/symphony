defmodule SymphonyElixir.Worker.CommandTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RuntimeProxy
  alias SymphonyElixir.Worker.Command
  alias SymphonyElixir.WorkerResult

  setup do
    previous_proxy_env = Map.new(RuntimeProxy.proxy_env_names(), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_proxy_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "records the Codex session marker and duration" do
    result =
      Command.run(
        %{command: "printf 'SYMPHONY_CODEX_SESSION_ID=session-123\\n'", timeout_seconds: 5},
        File.cwd!()
      )

    assert result.status == :passed
    assert result.session_id == "session-123"
    assert is_integer(result.duration_ms)
  end

  test "classifies missing commands as toolchain unavailable" do
    result = Command.run(%{command: "missing-symphony-tool", timeout_seconds: 5}, File.cwd!())
    assert result.status == :toolchain_unavailable
    assert result.exit_code == 127
  end

  test "does not hang on commands that read stdin (regression: codex exec waits on stdin)" do
    # `cat` blocks reading stdin; with stdin redirected to /dev/null it must exit immediately.
    result = Command.run(%{command: "cat", timeout_seconds: 3}, File.cwd!())
    assert result.status == :passed
    assert result.exit_code == 0
  end

  test "streams bounded output chunks while retaining the final bounded result" do
    owner = self()

    result =
      Command.run(
        %{command: "printf 'first\\n'; printf 'second\\n' >&2", timeout_seconds: 5},
        File.cwd!(),
        &send(owner, {:output, &1})
      )

    assert_receive {:output, chunk}
    assert chunk =~ "first"
    assert result.status == :passed
    assert result.detail =~ "first"
    assert result.detail =~ "second"
  end

  test "returns actual duration and recent output on timeout" do
    result =
      Command.run(
        %{command: "printf 'waiting\\n'; sleep 5", timeout_seconds: 1},
        File.cwd!()
      )

    assert result.status == :timed_out
    assert result.duration_ms >= 1_000
    assert result.detail =~ "waiting"
  end

  test "includes the truncation marker within the shared source output budget" do
    limit = WorkerResult.limits().max_source_output
    result = Command.run(%{command: "printf '%05000d' 0", timeout_seconds: 5}, File.cwd!())

    assert result.status == :passed
    assert byte_size(result.detail) == limit
    assert result.detail =~ "... (truncated)"
  end

  test "removes blank proxy variables from the child environment" do
    RuntimeProxy.proxy_env_names()
    |> Enum.with_index()
    |> Enum.each(fn {name, index} ->
      System.put_env(name, if(rem(index, 2) == 0, do: "", else: " \t "))
    end)

    result = Command.run(%{command: proxy_env_command(), timeout_seconds: 5}, File.cwd!())

    assert result.status == :passed
    assert parse_proxy_env(result.detail) == %{}
  end

  test "preserves nonblank proxy variables in the child environment" do
    expected = %{
      "HTTP_PROXY" => "http://upper-http.example.test:8080",
      "HTTPS_PROXY" => "http://upper-https.example.test:8443",
      "ALL_PROXY" => "http://upper-all.example.test:8888",
      "NO_PROXY" => "localhost,127.0.0.1",
      "http_proxy" => "http://lower-http.example.test:8080",
      "https_proxy" => "http://lower-https.example.test:8443",
      "all_proxy" => "http://lower-all.example.test:8888",
      "no_proxy" => ".example.test"
    }

    Enum.each(expected, fn {name, value} -> System.put_env(name, value) end)

    result = Command.run(%{command: proxy_env_command(), timeout_seconds: 5}, File.cwd!())

    assert result.status == :passed
    assert parse_proxy_env(result.detail) == expected
  end

  defp proxy_env_command do
    names = Enum.join(RuntimeProxy.proxy_env_names(), "|")
    "env | grep -E '^(#{names})=' || true"
  end

  defp parse_proxy_env(output) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn entry ->
      [name, value] = String.split(entry, "=", parts: 2)
      {name, value}
    end)
  end
end

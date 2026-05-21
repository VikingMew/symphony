defmodule SymphonyElixir.Workspace.HookRunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workspace.HookRunner

  test "run_local streams output and returns recent output with exit status" do
    dir = tmp_dir!("hook-runner-success")
    parent = self()

    assert {:ok, {"hello\n", 0}} =
             HookRunner.run_local("printf 'hello\\n'", dir, 1_000, fn chunk, recent_output ->
               send(parent, {:chunk, chunk, recent_output})
             end)

    assert_received {:chunk, "hello\n", "hello\n"}
  end

  test "run_local returns timeout diagnostics with recent output" do
    dir = tmp_dir!("hook-runner-timeout")

    assert {:error, {:workspace_hook_timeout, "local_command", 50, details}} =
             HookRunner.run_local("printf before-timeout; sleep 1", dir, 50, fn _chunk, _recent_output ->
               :ok
             end)

    assert details.elapsed_ms >= 50
    assert details.recent_output =~ "before-timeout"
  end

  test "append_recent_output keeps a bounded suffix" do
    output = HookRunner.append_recent_output("", String.duplicate("a", 5_000))

    assert byte_size(output) == 4_096
    assert output == String.duplicate("a", 4_096)
  end

  defp tmp_dir!(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end

defmodule SymphonyElixir.RepositoryVerificationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TestSupport.RetryTimerAssertions

  @root Path.expand("../..", __DIR__)

  @tag :verification_selection
  test "Mix selects a single ordinary test by file/line or tag without entering quality" do
    root = Path.join(System.tmp_dir!(), "selection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "scripts"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "mix.exs"), "defmodule Selection.MixProject do use Mix.Project; def project, do: [app: :selection, version: \"0.1.0\"] end")
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()")
    File.write!(Path.join(root, "scripts/quality.sh"), "exit 73")

    File.write!(Path.join(root, "test/selection_test.exs"), """
    defmodule SelectionTest do
      use ExUnit.Case
      @tag :chosen
      test "selected", do: assert(1 == 1)
      test "not selected", do: flunk("selection included another test")
    end
    """)

    for args <- [["test", "test/selection_test.exs:4"], ["test", "--only", "chosen"]] do
      {output, code} = System.cmd(System.find_executable("mix"), args, cd: root, stderr_to_stdout: true, env: [{"ERL_FLAGS", "+S 2:2"}])
      assert code == 0, output
      assert output =~ "1 excluded"
      assert output =~ "0 failures"
    end
  end

  test "runner preserves success, failure fields, assertion differences and complete logs" do
    root = Path.join(System.tmp_dir!(), "verification-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "scripts"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join(@root, "scripts/quality.exs"), Path.join(root, "scripts/quality.exs"))

    for gate <- ~w(check unit dialyzer) do
      File.write!(Path.join(root, "scripts/#{gate}.sh"), "echo '#{gate}: warning is informational'\n")
    end

    {_, 0} = System.cmd("git", ["init", "-q", root])
    {_, 0} = System.cmd("git", ["add", "."], cd: root)
    {before, 0} = System.cmd("git", ["diff", "--cached"], cd: root)
    {output, 0} = run_runner(root)
    success = read_summary(output)
    assert success["status"] == "passed"
    assert Enum.map(success["gates"], & &1["gate"]) == ~w(check unit dialyzer)
    assert Enum.map(success["gates"], & &1["status"]) == ~w(passed passed passed)
    assert length(String.split(output, "\n", trim: true)) == 4

    File.write!(Path.join(root, "scripts/unit.sh"), "elixir -e 'ExUnit.start(); defmodule Failure do use ExUnit.Case; test \"difference\" do assert 2 == 1 end end'\nexit 7\n")
    {output, 1} = run_runner(root)
    failure = read_summary(output)
    assert failure["status"] == "failed"
    assert failure["duration_unit"] == "millisecond"
    assert is_integer(failure["duration"])
    assert [_, failed, last] = failure["gates"]
    assert last["status"] == "passed"

    assert Map.take(failed, ~w(violation actual expected)) == %{
             "violation" => "gate_failed",
             "actual" => %{"exit_code" => 7},
             "expected" => %{"exit_code" => 0}
           }

    assert output =~ ~s("violation":"gate_failed")
    assert output =~ ~s("actual":{"exit_code":7})
    assert output =~ ~s("expected":{"exit_code":0})
    assert output =~ failed["log_path"]
    assert File.read!(failed["log_path"]) =~ "left:  2"
    assert File.read!(failed["log_path"]) =~ "right: 1"
    assert File.read!(failed["log_path"]) =~ "1 test, 1 failure"

    for gate <- failure["gates"] do
      assert File.regular?(gate["log_path"])
      assert is_integer(gate["duration"])
    end

    {after_run, 0} = System.cmd("git", ["diff", "--cached"], cd: root)
    assert after_run == before
    assert length(Path.wildcard(Path.join(root, "_build/quality/*/summary.json"))) == 2
  end

  test "retry timer evidence rejects a wrong scheduled delay without relying on log text" do
    owner = self()
    token = make_ref()

    pid =
      spawn(fn ->
        receive do
          :schedule ->
            due_at_ms = System.monotonic_time(:millisecond) + 11_000 + 400
            timer_ref = Process.send_after(self(), {:retry_issue, "fixture", token}, 11_000)
            send(owner, {:scheduled, timer_ref, due_at_ms})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    RetryTimerAssertions.trace_retry_timers(pid)
    send(pid, :schedule)
    assert_receive {:scheduled, timer_ref, due_at_ms}
    entry = %{retry_token: token, timer_ref: timer_ref, due_at_ms: due_at_ms}

    assert_raise ExUnit.AssertionError, fn ->
      RetryTimerAssertions.assert_retry_delay(pid, "fixture", %{entry | due_at_ms: due_at_ms + 1}, 11_000)
    end

    assert_raise ExUnit.AssertionError, fn ->
      RetryTimerAssertions.assert_retry_delay(pid, "fixture", entry, 10_000)
    end

    RetryTimerAssertions.assert_retry_delay(pid, "fixture", entry, 11_000)
  end

  test "outbound boundary rejects external hosts before DNS or transport" do
    for host <- ["api.linear.app", "example.invalid", "192.0.2.1", "localhost"] do
      assert_raise RuntimeError, ~r/violation=external_http.*expected=literal_loopback/, fn ->
        Req.get!("https://#{host}", retry: false)
      end
    end
  end

  test "outbound boundary rejects an external proxy even for loopback URLs" do
    assert_raise RuntimeError, ~r/violation=external_http.*expected=literal_loopback/, fn ->
      Req.get!("http://127.0.0.1:1", connect_options: [proxy: {:http, "example.invalid", 8080, []}], retry: false)
    end
  end

  test "outbound boundary allows a test-owned literal loopback service" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(socket, 0)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        :gen_tcp.close(socket)
      end)

    assert Req.get!("http://127.0.0.1:#{port}", retry: false).body == "ok"
    assert Task.await(server) == :ok
  end

  test "entrypoints keep manual validation independent and CI retains evidence" do
    workflow = File.read!(Path.join(@root, ".github/workflows/make-all.yml"))
    assert workflow =~ "run: scripts/setup.sh"
    assert workflow =~ "run: scripts/quality.sh"
    assert workflow =~ "if: always()"
    assert workflow =~ "path: _build/quality/"

    for gate <- ~w(check unit) do
      assert File.read!(Path.join(@root, "scripts/#{gate}.sh")) =~ "scripts/prepare_navigation_git_history.sh"
    end

    for path <- ~w(scripts/quality.sh scripts/quality.exs scripts/unit.sh .github/workflows/make-all.yml) do
      content = File.read!(Path.join(@root, path))
      # V-08: manual E2E and prompts may not enter the default gate.
      refute content =~ ~r/e2e\.sh|--only live_e2e|read -[rp]/
    end
  end

  defp run_runner(root) do
    {before, 0} = System.cmd("git", ["diff"], cd: root)
    result = System.cmd(System.find_executable("elixir"), ["scripts/quality.exs"], cd: root, stderr_to_stdout: true, env: [{"ERL_FLAGS", "+S 2:2"}])
    {after_run, 0} = System.cmd("git", ["diff"], cd: root)
    assert after_run == before
    result
  end

  defp read_summary(output) do
    path = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!() |> Map.fetch!("summary_path")
    path |> File.read!() |> Jason.decode!()
  end
end

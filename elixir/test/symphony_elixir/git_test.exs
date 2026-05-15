defmodule SymphonyElixir.GitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Git

  test "run normalizes runner return values and redacts sensitive output" do
    assert {:ok, "ok"} = Git.run("/tmp", ["status"], runner: fn _workspace, _args, _timeout -> {:ok, "ok"} end)
    assert {:ok, "plain"} = Git.run("/tmp", ["status"], runner: fn _workspace, _args, _timeout -> {"plain", 0} end)

    assert {:error, {:unexpected_git_result, :wat}} =
             Git.run("/tmp", ["status"], runner: fn _workspace, _args, _timeout -> :wat end)

    assert {:error, {:git_command_failed, ["push"], 1, redacted_output}} =
             Git.run("/tmp", ["push"],
               runner: fn _workspace, _args, _timeout ->
                 {"Authorization: Bearer secret-token api_key=abc123 token=def456", 1}
               end
             )

    assert redacted_output =~ "Authorization: [REDACTED]"
    assert redacted_output =~ "api_key=[REDACTED]"
    assert redacted_output =~ "token=[REDACTED]"

    assert {:error, {:git_command_timeout, ["fetch"], 1, reason_output}} =
             Git.run("/tmp", ["fetch"],
               runner: fn _workspace, _args, _timeout ->
                 {:error, {:git_command_timeout, ["fetch"], 1, "secret=abc"}}
               end
             )

    assert reason_output == "secret=[REDACTED]"
  end

  test "remote branch detection maps ls-remote output to booleans" do
    runner = fn
      "/repo", ["ls-remote", "--heads", "origin", "feature/one"], 300_000 ->
        {"abc refs/heads/feature/one\n", 0}

      "/repo", ["ls-remote", "--heads", "origin", "feature/missing"], 300_000 ->
        {"", 0}

      "/repo", ["ls-remote", "--heads", "origin", "feature/error"], 300_000 ->
        {"fatal: token=abc", 128}
    end

    assert {:ok, true} = Git.remote_branch_exists?("/repo", "feature/one", runner: runner)
    assert {:ok, false} = Git.remote_branch_exists?("/repo", "feature/missing", runner: runner)

    assert {:error, {:git_command_failed, _args, 128, "fatal: token=[REDACTED]"}} =
             Git.remote_branch_exists?("/repo", "feature/error", runner: runner)
  end

  test "checkout work branch fetches remote branches or creates local branches" do
    test_pid = self()

    runner = fn workspace, args, timeout ->
      send(test_pid, {:git, workspace, args, timeout})

      case args do
        ["ls-remote", "--heads", "upstream", "feature/remote"] -> {"abc refs/heads/feature/remote\n", 0}
        ["fetch", "upstream", "feature/remote"] -> {"", 0}
        ["checkout", "-B", "feature/remote", "upstream/feature/remote"] -> {"checked remote", 0}
        ["ls-remote", "--heads", "upstream", "feature/local"] -> {"", 0}
        ["checkout", "-B", "feature/local"] -> {"checked local", 0}
        ["ls-remote", "--heads", "upstream", "feature/error"] -> {"fatal", 128}
      end
    end

    assert {:ok, "checked remote"} =
             Git.checkout_work_branch("/repo", "feature/remote", remote: "upstream", runner: runner)

    assert {:ok, "checked local"} =
             Git.checkout_work_branch("/repo", "feature/local", remote: "upstream", runner: runner)

    assert {:error, {:git_command_failed, _args, 128, "fatal"}} =
             Git.checkout_work_branch("/repo", "feature/error", remote: "upstream", runner: runner)

    assert_receive {:git, "/repo", ["fetch", "upstream", "feature/remote"], 300_000}
    assert_receive {:git, "/repo", ["checkout", "-B", "feature/local"], 300_000}
  end

  test "merge branch fetches checks out merges and optionally pushes" do
    test_pid = self()

    runner = fn workspace, args, timeout ->
      send(test_pid, {:git, workspace, args, timeout})

      case args do
        ["ls-remote", "--heads", "origin", "feature/merge"] -> {"abc refs/heads/feature/merge\n", 0}
        ["fetch", "origin", "feature/merge"] -> {"", 0}
        ["checkout", "main"] -> {"", 0}
        ["merge", "--no-edit", "origin/feature/merge"] -> {"merged", 0}
        ["push", "origin", "main"] -> {"pushed", 0}
        ["ls-remote", "--heads", "origin", "feature/missing"] -> {"", 0}
      end
    end

    assert {:ok, "merged"} =
             Git.merge_branch("/repo", "feature/merge",
               base_branch: "main",
               push: true,
               runner: runner
             )

    assert {:error, {:remote_branch_not_found, "feature/missing"}} =
             Git.merge_branch("/repo", "feature/missing", base_branch: "main", runner: runner)

    assert_receive {:git, "/repo", ["fetch", "origin", "feature/merge"], 300_000}
    assert_receive {:git, "/repo", ["checkout", "main"], 300_000}
    assert_receive {:git, "/repo", ["merge", "--no-edit", "origin/feature/merge"], 300_000}
    assert_receive {:git, "/repo", ["push", "origin", "main"], 300_000}
  end

  test "real git command boundary reports success failure and timeout" do
    workspace = Path.join(System.tmp_dir!(), "symphony-git-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    try do
      assert {:ok, output} = Git.run(workspace, ["--version"])
      assert output =~ "git version"

      assert {:error, {:git_command_failed, ["definitely-not-a-command"], status, output}} =
               Git.run(workspace, ["definitely-not-a-command"])

      assert status != 0
      assert output =~ "definitely-not-a-command"

      assert {:error, {:git_command_timeout, ["-c", "alias.slow=!sleep 1", "slow"], 1, _output}} =
               Git.run(workspace, ["-c", "alias.slow=!sleep 1", "slow"], timeout_ms: 1)
    after
      File.rm_rf(workspace)
    end
  end
end

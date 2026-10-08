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

  test "prepares an exact task branch from one captured configured-default tip" do
    fixture = central_git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    central_git!(fixture.author, ["checkout", "-b", "feature/sym-160"])
    task_sha = commit_and_push_central_git!(fixture.author, "feature/sym-160", "task.txt", "task")
    central_git!(fixture.author, ["checkout", "trunk"])
    base_sha = commit_and_push_central_git!(fixture.author, "trunk", "base.txt", "base")
    central_git!(fixture.root, ["clone", fixture.remote, fixture.workspace])

    assert {:ok, prepared} =
             Git.prepare_work_branch(fixture.workspace, "trunk", "feature/sym-160")

    assert prepared.base_sha == base_sha
    assert prepared.task_sha == task_sha
    assert central_git!(fixture.workspace, ["branch", "--show-current"]) == "feature/sym-160"
    assert central_git!(fixture.workspace, ["merge-base", "--is-ancestor", task_sha, "HEAD"]) == ""
    assert central_git!(fixture.workspace, ["merge-base", "--is-ancestor", base_sha, "HEAD"]) == ""
    assert central_git!(fixture.workspace, ["merge-base", "refs/remotes/origin/trunk", "HEAD"]) == base_sha
  end

  test "starts a missing task branch at the captured configured-default tip" do
    fixture = central_git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)
    central_git!(fixture.root, ["clone", fixture.remote, fixture.workspace])

    assert {:ok, prepared} = Git.prepare_work_branch(fixture.workspace, "trunk", "feature/new")
    assert prepared.base_sha == fixture.main_sha
    assert prepared.task_sha == fixture.main_sha
    assert prepared.prepared_head == fixture.main_sha
  end

  test "fails when the fetched configured-default ref cannot be resolved" do
    runner = fn
      "/repo", ["fetch", "--no-tags", "origin", "+refs/heads/trunk:refs/remotes/origin/trunk"], 300_000 ->
        {"", 0}

      "/repo", ["rev-parse", "--verify", "refs/remotes/origin/trunk^{commit}"], 300_000 ->
        {"fatal: bad revision", 128}
    end

    assert {:error, {:git_command_failed, ["rev-parse" | _args], 128, "fatal: bad revision"}} =
             Git.prepare_work_branch("/repo", "trunk", "feature/sym-160", runner: runner)
  end

  test "fails when the prepared DAG does not retain the captured default merge base" do
    runner = fn
      "/repo", ["fetch", "--no-tags", "origin", "+refs/heads/trunk:refs/remotes/origin/trunk"], 300_000 ->
        {"", 0}

      "/repo", ["rev-parse", "--verify", "refs/remotes/origin/trunk^{commit}"], 300_000 ->
        {"base-sha\n", 0}

      "/repo", ["ls-remote", "--heads", "origin", "feature/sym-160"], 300_000 ->
        {"", 0}

      "/repo", ["checkout", "-B", "feature/sym-160", "base-sha"], 300_000 ->
        {"", 0}

      "/repo", ["merge-base", "--is-ancestor", "base-sha", target], 300_000
      when target in ["base-sha", "HEAD"] ->
        {"", 0}

      "/repo", ["rev-parse", "--verify", "HEAD^{commit}"], 300_000 ->
        {"prepared-sha\n", 0}

      "/repo", ["merge-base", "refs/remotes/origin/trunk", "HEAD"], 300_000 ->
        {"wrong-sha\n", 0}
    end

    assert {:error, {:git_postcondition_failed, :default_merge_base, "base-sha"}} =
             Git.prepare_work_branch("/repo", "trunk", "feature/sym-160", runner: runner)
  end

  defp central_git_fixture! do
    root = Path.join(System.tmp_dir!(), "git-boundary-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    author = Path.join(root, "author")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(root)
    central_git!(root, ["init", "--bare", "--initial-branch=trunk", remote])
    central_git!(root, ["clone", remote, author])
    central_git!(author, ["config", "user.email", "git@example.test"])
    central_git!(author, ["config", "user.name", "Git Test"])
    main_sha = commit_and_push_central_git!(author, "trunk", "README.md", "initial")
    %{root: root, remote: remote, author: author, workspace: workspace, main_sha: main_sha}
  end

  defp commit_and_push_central_git!(author, branch, file, content) do
    File.write!(Path.join(author, file), content)
    central_git!(author, ["add", file])
    central_git!(author, ["commit", "-m", content])
    central_git!(author, ["push", "origin", branch])
    central_git!(author, ["rev-parse", "HEAD"])
  end

  defp central_git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end

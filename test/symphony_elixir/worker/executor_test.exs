defmodule SymphonyElixir.Worker.ExecutorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Worker.{Config, ExecutionPayload, Executor, Payload}

  test "includes the repository project in the worker workflow context" do
    assert {:ok, payload} = panel_payload() |> ExecutionPayload.from_task_payload() |> Payload.parse()

    config = %Config{
      panel_url: "http://panel.test",
      registration_token: "worker-token",
      worker_name: "worker-test",
      workspace_root: "/tmp/symphony-workspaces",
      cache_root: "/tmp/symphony-cache",
      log_root: "/tmp/symphony-logs"
    }

    workflow = Executor.codex_workflow(config, %{config: %{}}, payload)

    assert workflow.config["project"]["repository_url"] ==
             "git@github.com:VikingMew/symphony.git"

    assert workflow.config["project"]["default_branch"] == "main"
    assert {:ok, settings} = Schema.parse(workflow.config)
    assert settings.project.repository_url == "git@github.com:VikingMew/symphony.git"
  end

  test "prepares a new task branch from the latest configured default branch" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    first_base = fixture.main_sha
    workspace = Path.join(fixture.root, "lease")
    assert {:ok, first} = Executor.prepare(payload(fixture.remote), workspace)
    assert first.base_sha == first_base
    assert first.prepared_head == first_base
    assert first.default_branch == "trunk"
    assert first.task_branch == "feature/sym-74"
    assert git!(workspace, ["branch", "--show-current"]) == "feature/sym-74"

    next_base = commit_and_push!(fixture.author, "trunk", "next.txt", "next default")
    assert {:ok, second} = Executor.prepare(payload(fixture.remote), workspace)
    assert second.base_sha == next_base
    assert second.prepared_head == next_base
    assert git!(workspace, ["rev-parse", "refs/remotes/origin/trunk"]) == next_base
  end

  test "preserves an existing remote task branch while refreshing the default branch" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    git!(fixture.author, ["checkout", "-b", "feature/sym-74"])
    task_sha = commit_and_push!(fixture.author, "feature/sym-74", "task.txt", "task commit")
    git!(fixture.author, ["checkout", "trunk"])
    base_sha = commit_and_push!(fixture.author, "trunk", "new-base.txt", "advance default")

    workspace = Path.join(fixture.root, "lease")
    assert {:ok, source} = Executor.prepare(payload(fixture.remote), workspace)
    assert source.base_sha == base_sha
    assert source.prepared_head == task_sha
    assert source.task_branch == "feature/sym-74"
    assert git!(workspace, ["rev-parse", "refs/remotes/origin/trunk"]) == base_sha
  end

  test "rebuilds a stale lease workspace before fetching source" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    workspace = Path.join(fixture.root, "lease")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "stale.txt"), "stale checkout")
    base_sha = commit_and_push!(fixture.author, "trunk", "latest.txt", "latest default")

    assert {:ok, source} = Executor.prepare(payload(fixture.remote), workspace)
    assert source.base_sha == base_sha
    refute File.exists?(Path.join(workspace, "stale.txt"))
  end

  test "returns a typed preparation error when the configured default branch cannot be fetched" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    bad_payload = %{payload(fixture.remote) | default_branch: "missing"}

    assert {:error, {:source_preparation_failed, :default_branch_fetch_failed, %{status: :failed}}} =
             Executor.prepare(bad_payload, Path.join(fixture.root, "lease"))
  end

  test "does not start hooks after a source preparation failure" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    marker = Path.join(fixture.root, "hook-ran")

    execution =
      panel_payload()
      |> put_in(["repository", "url"], fixture.remote)
      |> put_in(["repository", "source_ref"], "missing")
      |> put_in(["repository", "implementation_branch"], "feature/sym-74")
      |> put_in(["hooks", "after_create"], "touch #{marker}")
      |> ExecutionPayload.from_task_payload()

    config = %Config{
      panel_url: "http://panel.test",
      registration_token: "worker-token",
      worker_name: "worker-test",
      workspace_root: Path.join(fixture.root, "workspaces"),
      cache_root: Path.join(fixture.root, "cache"),
      log_root: Path.join(fixture.root, "logs")
    }

    claim = %{
      "project_id" => "project-1",
      "task_id" => "task-1",
      "lease_id" => "lease-1",
      "run_id" => "run-1",
      "issue_id" => "issue-1",
      "execution" => execution
    }

    result = Executor.execute(config, claim)
    assert result.status == :failed
    assert result.reason =~ "source_preparation_failed"
    assert result.reason =~ "default_branch_fetch_failed"
    refute File.exists?(marker)
  end

  defp payload(remote) do
    assert {:ok, payload} =
             panel_payload()
             |> put_in(["repository", "url"], remote)
             |> put_in(["repository", "source_ref"], "trunk")
             |> put_in(["repository", "implementation_branch"], "feature/sym-74")
             |> ExecutionPayload.from_task_payload()
             |> Payload.parse()

    payload
  end

  defp git_fixture! do
    root = Path.join(System.tmp_dir!(), "executor-git-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    author = Path.join(root, "author")
    File.mkdir_p!(root)
    git!(root, ["init", "--bare", "--initial-branch=trunk", remote])
    git!(root, ["clone", remote, author])
    git!(author, ["config", "user.email", "worker@example.test"])
    git!(author, ["config", "user.name", "Worker Test"])
    main_sha = commit_and_push!(author, "trunk", "README.md", "initial")
    %{root: root, remote: remote, author: author, main_sha: main_sha}
  end

  defp commit_and_push!(author, branch, file, message) do
    File.write!(Path.join(author, file), message)
    git!(author, ["add", file])
    git!(author, ["commit", "-m", message])
    git!(author, ["push", "origin", branch])
    git!(author, ["rev-parse", "HEAD"])
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp panel_payload do
    %{
      "issue" => %{"identifier" => "SYM-68", "title" => "Propagate project config"},
      "prompt" => "Implement the task.",
      "workflow_profile" => "implementation",
      "repository" => %{
        "url" => "git@github.com:VikingMew/symphony.git",
        "source_ref" => "main",
        "implementation_branch" => "vikingmew-sym-68"
      },
      "hooks" => %{
        "after_create" => nil,
        "before_run" => nil,
        "after_run" => nil,
        "before_remove" => nil,
        "timeout_ms" => 1_000
      },
      "codex" => %{
        "command" => "codex app-server",
        "pre_start_commands" => [],
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write",
        "turn_sandbox_policy" => nil
      },
      "limits" => %{"turn_timeout_ms" => 60_000, "read_timeout_ms" => 5_000, "stall_timeout_ms" => 30_000},
      "required_gates" => [],
      "handoff" => %{}
    }
  end
end

defmodule SymphonyElixir.Worker.ExecutorTest do
  use ExUnit.Case, async: false

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

  test "host push requires the exact description directive and root patch" do
    workspace = Path.join(System.tmp_dir!(), "executor-host-push-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    payload = implementation_payload("\n\n交付路径:宿主 push\nImplement the task.")

    missing_handoff = %{
      handoff: nil,
      detail: nil,
      delivery_evidence: {:incomplete, %{"missing" => ["create_pull_request", "linear_task_update"]}}
    }

    for codex <- [
          %{missing_handoff | detail: "需宿主 push"},
          %{missing_handoff | detail: "permission denied with 403 workflow scope"},
          %{missing_handoff | detail: %{status: "blocked", marker: "需宿主 push"}}
        ] do
      assert {:error, {:handoff_failed, :missing_handoff}, _evidence} =
               Executor.handoff_requirement(payload, codex, workspace)
    end

    File.write!(Path.join(workspace, "SYM-68.patch"), "binary-safe patch")

    for description <- [
          "\n\n交付路径:宿主 push\nImplement the task.",
          "  交付路径:宿主 push  ",
          "交付路径:宿主 push ",
          "交付路径:宿主 push\r\n"
        ] do
      assert {:ok, {:blocked, {:handoff_failed, {:host_push_required, %{"marker" => "需宿主 push", "patch_path" => "SYM-68.patch"}}}, %{"marker" => "需宿主 push", "patch_path" => "SYM-68.patch"}}} =
               payload
               |> put_in(
                 [Access.key!(:codex), Access.key!(:issue), Access.key!(:description)],
                 description
               )
               |> Executor.handoff_requirement(missing_handoff, workspace)
    end

    for description <- [
          "Implement the task.",
          "交付路径:宿主  push",
          "交付路径:宿主 Push"
        ] do
      assert {:error, {:handoff_failed, :missing_handoff}, _evidence} =
               payload
               |> put_in([Access.key!(:codex), Access.key!(:issue), Access.key!(:description)], description)
               |> Executor.handoff_requirement(missing_handoff, workspace)
    end
  end

  test "completed delivery audit evidence blocks a missing final handoff" do
    events = [
      %{
        tool: "linear_task_update",
        status: "success",
        arguments: %{"comment" => "done", "target_state" => "  READY TO MERGE  "},
        result: %{"requested_state" => "Ready to Merge"}
      },
      %{
        tool: "create_pull_request",
        status: "success",
        arguments: %{},
        result: %{"url" => "https://github.com/VikingMew/symphony/pull/105"}
      }
    ]

    evidence = %{
      "pr_url" => "https://github.com/VikingMew/symphony/pull/105",
      "linear_state" => "Ready to Merge"
    }

    assert Executor.completed_delivery_evidence(events) == {:complete, evidence}

    full_pr =
      put_in(List.last(events), [:result], %{
        "url" => evidence["pr_url"],
        "head" => "vikingmew-sym-108",
        "head_oid" => "abc123"
      })

    assert {:complete,
            %{
              "pr_url" => "https://github.com/VikingMew/symphony/pull/105",
              "branch" => "vikingmew-sym-108",
              "commit" => "abc123",
              "linear_state" => "Ready to Merge"
            }} = Executor.completed_delivery_evidence([hd(events), full_pr])

    codex = %{handoff: nil, delivery_evidence: {:complete, evidence}}

    assert {:ok, {:blocked, {:handoff_failed, {:completed_delivery_missing_handoff, ^evidence}}, ^evidence}} =
             Executor.handoff_requirement(implementation_payload("Implement the task."), codex, "/tmp")

    assert Executor.completed_delivery_evidence(tl(events)) ==
             {:incomplete, %{"missing" => ["linear_task_update"]}}

    assert Executor.completed_delivery_evidence([hd(events)]) ==
             {:incomplete, %{"missing" => ["create_pull_request"]}}

    failed_pr = put_in(List.last(events), [:status], "failure")

    assert Executor.completed_delivery_evidence([hd(events), failed_pr]) ==
             {:incomplete, %{"missing" => ["create_pull_request"]}}

    incomplete =
      Executor.completed_delivery_evidence([
        hd(events),
        %{tool: "create_pull_request", status: "success", result: %{}}
      ])

    assert incomplete == {:incomplete, %{"missing" => ["create_pull_request.result.url"]}}

    wrong_state = put_in(hd(events), [:arguments, "target_state"], "Blocked")

    assert Executor.completed_delivery_evidence([wrong_state, List.last(events)]) ==
             {:incomplete, %{"missing" => ["linear_task_update.arguments.target_state"]}}

    assert Executor.completed_delivery_evidence([
             wrong_state,
             %{tool: "create_pull_request", status: "success", result: %{}}
           ]) ==
             {:incomplete,
              %{
                "missing" => [
                  "create_pull_request.result.url",
                  "linear_task_update.arguments.target_state"
                ]
              }}

    assert {:error, {:handoff_failed, :missing_handoff}, %{"missing" => ["create_pull_request.result.url"]}} =
             Executor.handoff_requirement(
               implementation_payload("Implement the task."),
               %{handoff: nil, delivery_evidence: incomplete},
               "/tmp"
             )
  end

  test "refinement requires a successful review-state update from the current session" do
    successful_update = %{
      tool: "linear_task_update",
      status: "success",
      arguments: %{"target_state" => "  NEEDS REFINEMENT REVIEW  "},
      result: %{"requested_state" => "Needs Refinement Review"}
    }

    assert Executor.refinement_completion_evidence([successful_update]) ==
             {:complete, %{"linear_state" => "Needs Refinement Review"}}

    assert {:ok, :ready} =
             Executor.handoff_requirement(
               refinement_payload(),
               %{
                 handoff: nil,
                 delivery_evidence: {:complete, %{"linear_state" => "Needs Refinement Review"}}
               },
               "/tmp"
             )

    incomplete =
      Executor.refinement_completion_evidence([
        %{successful_update | status: "failure"},
        put_in(successful_update, [:arguments, "target_state"], "Blocked")
      ])

    evidence = %{
      "missing" => ["linear_task_update(target_state: Needs Refinement Review)"],
      "reason" => "missing_refinement_completion"
    }

    assert incomplete ==
             {:incomplete, %{"missing" => ["linear_task_update(target_state: Needs Refinement Review)"]}}

    assert {:ok, {:blocked, {:handoff_failed, {:missing_refinement_completion, ^evidence}}, ^evidence}} =
             Executor.handoff_requirement(
               refinement_payload(),
               %{handoff: nil, delivery_evidence: incomplete},
               "/tmp"
             )
  end

  test "prepares a new task branch from the latest configured default branch" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    first_base = fixture.main_sha
    workspace = Path.join(fixture.root, "lease")
    assert {:ok, first} = Executor.prepare(payload(fixture.remote_url), workspace, no_progress())
    assert first.base_sha == first_base
    assert first.prepared_head == first_base
    assert first.default_branch == "trunk"
    assert first.task_branch == "feature/sym-74"
    assert git!(workspace, ["branch", "--show-current"]) == "feature/sym-74"
    assert File.regular?(Path.join(workspace, ".git/shallow"))

    next_base = commit_and_push!(fixture.author, "trunk", "next.txt", "next default")
    assert {:ok, second} = Executor.prepare(payload(fixture.remote_url), workspace, no_progress())
    assert second.base_sha == next_base
    assert second.prepared_head == next_base
    assert git!(workspace, ["rev-parse", "refs/remotes/origin/trunk"]) == next_base
  end

  test "streams source progress without writing phase into executor payloads" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)
    owner = self()
    progress = fn phase, payload -> send(owner, {:source_progress, phase, payload}) end

    assert {:ok, _source} =
             Executor.prepare(payload(fixture.remote_url), Path.join(fixture.root, "lease"), progress)

    assert_receive {:source_progress, "source_preparation", %{source: "worker", operation: "git_clone", status: "started"} = started}

    assert Map.has_key?(started, :phase) == false
    assert_receive {:source_progress, "source_preparation", %{operation: "git_clone", status: "output"}}
    assert_receive {:source_progress, "source_preparation", %{operation: "git_clone", status: "completed"}}
  end

  test "maps a source command timeout to bounded phase evidence" do
    root = Path.join(System.tmp_dir!(), "executor-timeout-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    helper = Path.join(bin, "git-remote-delay")
    File.mkdir_p!(bin)

    File.write!(helper, "#!/bin/sh\nprintf 'waiting for remote source\\n' >&2\nsleep 5\n")
    File.chmod!(helper, 0o755)

    previous_path = System.get_env("PATH")
    previous_git_exec_path = System.get_env("GIT_EXEC_PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    System.put_env("GIT_EXEC_PATH", bin)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      restore_env("GIT_EXEC_PATH", previous_git_exec_path)
      File.rm_rf(root)
    end)

    timed_payload = %{payload("delay::repository") | initialize_timeout_seconds: 1}
    owner = self()
    progress = fn phase, event -> send(owner, {:source_progress, phase, event}) end

    assert {:error, :source_preparation_timeout,
            %{
              phase: "clone_failed",
              command_status: "timed_out",
              duration_ms: duration_ms,
              output: output
            }} = Executor.prepare(timed_payload, Path.join(root, "lease"), progress)

    assert duration_ms >= 1_000
    assert output =~ "waiting for remote source"

    assert_receive {:source_progress, "source_preparation", %{operation: "git_clone", status: "failed", detail: detail}}

    assert detail =~ "waiting for remote source"
  end

  test "deepens and merges the captured default tip into an existing remote task branch" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    git!(fixture.author, ["checkout", "-b", "feature/sym-74"])
    task_sha = commit_and_push!(fixture.author, "feature/sym-74", "task.txt", "task commit")
    git!(fixture.author, ["checkout", "trunk"])
    base_sha = commit_and_push!(fixture.author, "trunk", "new-base.txt", "advance default")

    workspace = Path.join(fixture.root, "lease")
    progress = source_progress_to(self())
    assert {:ok, source} = Executor.prepare(payload(fixture.remote_url), workspace, progress)
    assert source.base_sha == base_sha
    assert_synced_source(source, workspace, task_sha, base_sha)
    assert File.regular?(Path.join(workspace, ".git/shallow"))
    assert_receive {:source_progress, "source_preparation", %{operation: "git_deepen", status: "started"}}
  end

  test "rebuilds a stale lease workspace before fetching source" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    workspace = Path.join(fixture.root, "lease")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "stale.txt"), "stale checkout")
    base_sha = commit_and_push!(fixture.author, "trunk", "latest.txt", "latest default")

    assert {:ok, source} = Executor.prepare(payload(fixture.remote_url), workspace, no_progress())
    assert source.base_sha == base_sha
    assert File.exists?(Path.join(workspace, "stale.txt")) == false
  end

  test "returns a typed preparation error when the configured default branch cannot be fetched" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    bad_payload = %{payload(fixture.remote_url) | default_branch: "missing"}

    assert {:error, {:source_preparation_failed, :clone_failed, %{status: :failed}}} =
             Executor.prepare(bad_payload, Path.join(fixture.root, "lease"), no_progress())
  end

  test "does not start hooks after a source preparation failure" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    marker = Path.join(fixture.root, "hook-ran")

    execution =
      panel_payload()
      |> put_in(["source", "repository"], fixture.remote_url)
      |> put_in(["source", "default_branch"], "missing")
      |> put_in(["source", "implementation_branch"], "feature/sym-74")
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

    assert result.reason == :source_preparation_failed
    assert_source_failure(result.failure_evidence)

    assert File.exists?(marker) == false
  end

  test "preserves typed Codex execution capability failures" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    codex_binary = Path.join(fixture.root, "fake-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-worker-bwrap"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-worker-bwrap"}}}'
          printf '%s\\n' 'bwrap: No permissions to create a new namespace' >&2
          sleep 5
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    execution =
      panel_payload()
      |> put_in(["source", "repository"], fixture.remote_url)
      |> put_in(["source", "default_branch"], "trunk")
      |> put_in(["source", "implementation_branch"], "feature/sym-95")
      |> put_in(["codex", "command"], "#{codex_binary} app-server")
      |> put_in(["codex", "thread_sandbox"], "danger-full-access")
      |> put_in(["codex", "turn_sandbox_policy"], %{"type" => "dangerFullAccess"})
      |> put_in(["limits", "turn_timeout_ms"], 10_000)
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
      "run_attempt" => 1,
      "lease_attempt" => 1,
      "issue_id" => "issue-1",
      "issue_identifier" => "SYM-95",
      "worker_id" => "worker-1",
      "session_id" => "session-1",
      "execution" => execution
    }

    result = Executor.execute(config, claim)

    assert result.status == :failed
    assert result.reason == :execution_capability_unavailable
    assert result.detail =~ "bwrap: No permissions to create a new namespace"
  end

  test "shutdown during Codex execution terminates the app-server process" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    pid_file = Path.join(fixture.root, "fake-codex.pid")
    codex_binary = Path.join(fixture.root, "fake-codex")

    File.write!(codex_binary, """
    #!/bin/sh
    printf '%s\\n' "$$" > #{pid_file}
    trap 'exit 0' TERM INT HUP

    count=0
    while IFS= read -r line; do
      count=$((count + 1))

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-worker-cancel"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-worker-cancel"}}}'
          while true; do sleep 1; done
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    execution =
      panel_payload()
      |> put_in(["source", "repository"], fixture.remote_url)
      |> put_in(["source", "default_branch"], "trunk")
      |> put_in(["source", "implementation_branch"], "feature/sym-107")
      |> put_in(["codex", "command"], "#{codex_binary} app-server")
      |> put_in(["codex", "thread_sandbox"], "danger-full-access")
      |> put_in(["codex", "turn_sandbox_policy"], %{"type" => "dangerFullAccess"})
      |> put_in(["limits", "turn_timeout_ms"], 60_000)
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
      "run_attempt" => 1,
      "lease_attempt" => 1,
      "issue_id" => "issue-1",
      "issue_identifier" => "SYM-107",
      "worker_id" => "worker-1",
      "session_id" => "session-1",
      "execution" => execution
    }

    owner = self()

    task =
      Task.async(fn ->
        Executor.execute(config, claim, fn phase, payload -> send(owner, {:progress, phase, payload}) end)
      end)

    assert_receive {:progress, "codex_session_started", %{session_id: "thread-worker-cancel-turn-worker-cancel"}}, 5_000
    codex_pid = pid_file |> File.read!() |> String.trim()

    assert os_process_alive?(codex_pid)
    Process.exit(task.pid, :shutdown)

    assert %{status: :cancelled, detail: "cancelled during codex app-server run"} = Task.await(task, 10_000)
    eventually(fn -> os_process_alive?(codex_pid) == false end)
  end

  defp payload(remote) do
    assert {:ok, payload} =
             panel_payload()
             |> put_in(["source", "repository"], remote)
             |> put_in(["source", "default_branch"], "trunk")
             |> put_in(["source", "implementation_branch"], "feature/sym-74")
             |> ExecutionPayload.from_task_payload()
             |> Payload.parse()

    payload
  end

  defp implementation_payload(description) do
    assert {:ok, payload} =
             panel_payload()
             |> put_in(["issue", "description"], description)
             |> put_in(["handoff", "policy"], "push_pr_then_restricted_linear")
             |> ExecutionPayload.from_task_payload()
             |> Payload.parse()

    payload
  end

  defp refinement_payload do
    assert {:ok, payload} =
             panel_payload()
             |> put_in(["workflow_profile"], "refinement")
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
    %{root: root, remote: remote, remote_url: "file://#{remote}", author: author, main_sha: main_sha}
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
      # docs/negative-assertion-audit.md control-flow contract: fail explicitly if this branch is reached.
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd("sh", ["-c", "kill -0 #{pid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp panel_payload do
    %{
      "issue" => %{
        "identifier" => "SYM-68",
        "title" => "Propagate project config",
        "description" => "Propagate the project configuration."
      },
      "prompt" => "Implement the task.",
      "workflow_profile" => "implementation",
      "source" => %{
        "repository" => "git@github.com:VikingMew/symphony.git",
        "default_branch" => "main",
        "implementation_branch" => "vikingmew-sym-68",
        "source_strategy" => "clone",
        "checkout_depth" => 1
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
      "limits" => %{
        "initialize_timeout_ms" => 60_000,
        "turn_timeout_ms" => 60_000,
        "read_timeout_ms" => 5_000,
        "stall_timeout_ms" => 30_000
      },
      "required_gates" => [],
      "handoff" => %{}
    }
  end

  defp no_progress, do: fn _phase, _payload -> :ok end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp source_progress_to(owner), do: fn phase, event -> send(owner, {:source_progress, phase, event}) end

  defp assert_synced_source(source, workspace, task_sha, base_sha) do
    assert source.task_sha == task_sha
    assert source.prepared_head != task_sha
    assert source.task_branch == "feature/sym-74"
    assert git!(workspace, ["rev-parse", "refs/remotes/origin/trunk"]) == base_sha
    assert git!(workspace, ["merge-base", "--is-ancestor", task_sha, "HEAD"]) == ""
    assert git!(workspace, ["merge-base", "--is-ancestor", base_sha, "HEAD"]) == ""
    assert git!(workspace, ["merge-base", "refs/remotes/origin/trunk", "HEAD"]) == base_sha
  end

  defp assert_source_failure(evidence) do
    assert evidence.phase == "clone_failed"
    assert evidence.operation == "clone"
  end

  test "keeps an existing task head unchanged when it already contains the captured base" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    base_sha = commit_and_push!(fixture.author, "trunk", "base.txt", "advance default")
    git!(fixture.author, ["checkout", "-b", "feature/sym-74"])
    task_sha = commit_and_push!(fixture.author, "feature/sym-74", "task.txt", "task after base")
    owner = self()
    progress = fn phase, event -> send(owner, {:source_progress, phase, event}) end

    assert {:ok, source} =
             Executor.prepare(payload(fixture.remote_url), Path.join(fixture.root, "lease"), progress)

    assert source.base_sha == base_sha
    assert source.task_sha == task_sha
    assert source.prepared_head == task_sha
    refute_receive {:source_progress, "source_preparation", %{operation: "git_merge", status: "started"}}
  end

  test "returns a checkout preparation failure when histories have no common ancestor" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    git!(fixture.author, ["checkout", "--orphan", "feature/sym-74"])
    git!(fixture.author, ["rm", "-rf", "."])
    task_sha = commit_and_push!(fixture.author, "feature/sym-74", "orphan.txt", "orphan task")
    git!(fixture.author, ["checkout", "trunk"])
    _base_sha = commit_and_push!(fixture.author, "trunk", "base.txt", "advance default")

    assert {:error, {:source_preparation_failed, failure, %{status: :failed, detail: detail}}} =
             Executor.prepare(payload(fixture.remote_url), Path.join(fixture.root, "lease"), no_progress())

    assert failure in [:merge_base_exhausted, :merge_base_no_progress]
    assert detail =~ "common ancestor" or detail =~ "no additional commits"
    assert task_sha != fixture.main_sha
  end

  test "returns a typed checkout preparation failure on merge conflict" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    git!(fixture.author, ["checkout", "-b", "feature/sym-74"])
    _task_sha = commit_and_push!(fixture.author, "feature/sym-74", "README.md", "task edit")
    git!(fixture.author, ["checkout", "trunk"])
    _base_sha = commit_and_push!(fixture.author, "trunk", "README.md", "default edit")

    assert {:error, {:source_preparation_failed, :task_branch_merge_failed, failed}} =
             Executor.prepare(payload(fixture.remote_url), Path.join(fixture.root, "lease"), no_progress())

    assert failed.status == :failed
    assert failed.detail =~ "CONFLICT"
  end

  test "classifies a targeted deepen fetch failure as fetch evidence" do
    fixture = git_fixture!()
    on_exit(fn -> File.rm_rf(fixture.root) end)

    git!(fixture.author, ["checkout", "-b", "feature/sym-74"])
    _task_sha = commit_and_push!(fixture.author, "feature/sym-74", "task.txt", "task commit")
    git!(fixture.author, ["checkout", "trunk"])
    _base_sha = commit_and_push!(fixture.author, "trunk", "base.txt", "advance default")
    workspace = Path.join(fixture.root, "lease")

    progress = fn
      "source_preparation", %{operation: "git_merge_base", status: "completed"} ->
        git!(workspace, ["remote", "set-url", "origin", "file://#{Path.join(fixture.root, "missing.git")}"])

      _phase, _event ->
        :ok
    end

    assert {:error, {:source_preparation_failed, :history_deepen_failed, failed}} =
             Executor.prepare(payload(fixture.remote_url), workspace, progress)

    assert failed.status == :failed
  end
end

defmodule SymphonyElixir.Workspace.SourcePreparationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TestSupport.FakePersistence

  test "bundled split workflow package parses and validates against runtime schema" do
    workflow_path = Path.expand("../../../workflow.yml", __DIR__)

    assert {:ok, loaded} = SymphonyElixir.Workflow.load(workflow_path)
    assert {:ok, _settings} = Schema.parse(loaded.config)
  end

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "structured project bootstrap generates after_create hook when explicit hook is omitted" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "structured bootstrap\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_repository_url: template_repo,
        project_setup_commands: ["echo setup > setup.txt"]
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-PROJECT")
      assert File.read!(Path.join(workspace, "README.md")) == "structured bootstrap\n"
      assert File.read!(Path.join(workspace, "setup.txt")) == "setup\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree source strategy auto-clones base repo and creates per-issue worktrees" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-source-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      base_path = Path.join([test_root, "cache", "base"])
      worktree_root = Path.join(test_root, "worktrees")

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "worktree source\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_repository_url: source_repo,
        project_default_branch: "main",
        project_source_strategy: "worktree",
        workspace_repository_base_root: base_path,
        workspace_worktree_base_root: worktree_root,
        project_setup_commands: ["printf setup > setup.txt"],
        hook_after_create: "printf after > after.txt"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("WT-1")
      assert String.ends_with?(first_workspace, "/worktrees/WT-1")
      assert File.read!(Path.join(repository_cache_path(base_path, source_repo, "main"), "README.md")) == "worktree source\n"
      assert File.read!(Path.join(first_workspace, "README.md")) == "worktree source\n"
      assert File.read!(Path.join(first_workspace, "setup.txt")) == "setup"
      assert File.read!(Path.join(first_workspace, "after.txt")) == "after"
      assert File.exists?(Path.join(first_workspace, ".git"))

      File.write!(Path.join(source_repo, "README.md"), "worktree source updated\n")
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "update default branch"])

      assert {:ok, second_workspace} = Workspace.create_for_issue("WT-2")
      assert String.ends_with?(second_workspace, "/worktrees/WT-2")
      assert File.read!(Path.join(second_workspace, "README.md")) == "worktree source updated\n"

      base_repo = repository_cache_path(base_path, source_repo, "main")
      {source_head, 0} = System.cmd("git", ["-C", source_repo, "rev-parse", "main"])
      {base_head, 0} = System.cmd("git", ["-C", base_repo, "rev-parse", "main"])
      assert String.trim(base_head) == String.trim(source_head)
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree source strategy replaces empty stale base directory tree" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-empty-stale-base-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      base_path = Path.join([test_root, "cache", "base"])
      worktree_root = Path.join(test_root, "worktrees")

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "worktree source\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      stale_base_path = repository_cache_path(base_path, source_repo, "main")
      File.mkdir_p!(Path.join(stale_base_path, "WT-STALE"))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_repository_url: source_repo,
        project_default_branch: "main",
        project_source_strategy: "worktree",
        workspace_repository_base_root: base_path,
        workspace_worktree_base_root: worktree_root
      )

      assert {:ok, workspace} = Workspace.create_for_issue("WT-STALE")
      assert String.ends_with?(workspace, "/worktrees/WT-STALE")
      assert File.read!(Path.join(stale_base_path, "README.md")) == "worktree source\n"
      assert File.read!(Path.join(workspace, "README.md")) == "worktree source\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "structured project bootstrap clone commands are noninteractive" do
    assert {:ok, ssh_settings} =
             Schema.parse(%{
               project: %{
                 repository_url: "git@example.com:org/repo.git",
                 default_branch: "master",
                 checkout_depth: 1
               }
             })

    ssh_hook = Schema.generated_project_bootstrap_commands(ssh_settings)
    assert ssh_hook =~ "GIT_TERMINAL_PROMPT=0"
    assert ssh_hook =~ "GIT_ASKPASS="
    assert ssh_hook =~ "SSH_ASKPASS="
    assert ssh_hook =~ "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new'"
    assert ssh_hook =~ "git -c credential.helper= -c core.askPass= -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 clone --progress --depth 1 --branch 'master' 'git@example.com:org/repo.git' ."

    assert {:ok, https_settings} =
             Schema.parse(%{
               project: %{
                 repository_url: "https://example.com/org/repo.git",
                 default_branch: "main",
                 checkout_depth: 1
               }
             })

    https_hook = Schema.generated_project_bootstrap_commands(https_settings)
    assert https_hook =~ "GIT_TERMINAL_PROMPT=0"
    assert https_hook =~ "GIT_ASKPASS="
    assert https_hook =~ "SSH_ASKPASS="
    refute https_hook =~ "GIT_SSH_COMMAND"
    assert https_hook =~ "git -c credential.helper= -c core.askPass= -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 clone --progress --depth 1 --branch 'main' 'https://example.com/org/repo.git' ."
  end

  test "explicit after_create hook runs after structured project bootstrap" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-bootstrap-precedence-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(workspace_root, "source")
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "structured first\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_repository_url: template_repo,
        project_setup_commands: ["echo setup > setup.txt"],
        hook_after_create: "cat README.md > marker.txt"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-PRECEDENCE")
      assert File.read!(Path.join(workspace, "setup.txt")) == "setup\n"
      assert File.read!(Path.join(workspace, "marker.txt")) == "structured first\n"
      assert File.exists?(Path.join(workspace, ".git"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace recreates existing issue directory and deletes local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "first\n"
      refute File.exists?(Path.join(second_workspace, "local-progress.txt"))
      refute File.exists?(Path.join([second_workspace, "deps", "cache.txt"]))
      refute File.exists?(Path.join([second_workspace, "_build", "artifact.txt"]))
      refute File.exists?(Path.join([second_workspace, "tmp", "scratch.txt"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace labels structured project bootstrap failures separately from after_create hooks" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-bootstrap-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_setup_commands: ["echo setup failed && exit 17"]
      )

      assert {:error, {:workspace_hook_failed, "project_bootstrap", 17, output}} =
               Workspace.create_for_issue("MT-PROJECT-BOOTSTRAP-FAIL")

      assert output =~ "setup failed"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 50,
        hook_after_create: "echo before-timeout; sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 50, details}} =
               Workspace.create_for_issue("MT-TIMEOUT")

      assert details.elapsed_ms >= 50
      assert details.recent_output =~ "before-timeout"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace uses initialize timeout for project bootstrap separately from hook timeout" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-initialize-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        initialize_timeout_ms: 50,
        hook_timeout_ms: 1_000,
        project_setup_commands: ["echo initializing; sleep 1"],
        hook_after_create: "touch after-create"
      )

      assert {:error, {:workspace_hook_timeout, "project_bootstrap", 50, details}} =
               Workspace.create_for_issue("MT-INITIALIZE-TIMEOUT")

      assert details.elapsed_ms >= 50
      assert details.recent_output =~ "initializing"
      refute File.exists?(Path.join([workspace_root, "MT-INITIALIZE-TIMEOUT", "after-create"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "worktree bootstrap clone uses initialize timeout" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-initialize-timeout-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH") || ""

    try do
      fake_bin = Path.join(test_root, "bin")
      File.mkdir_p!(fake_bin)

      fake_git = Path.join(fake_bin, "git")

      File.write!(fake_git, """
      #!/bin/sh
      echo "Receiving objects: fake slow clone"
      sleep 1
      exit 0
      """)

      File.chmod!(fake_git, 0o755)
      System.put_env("PATH", fake_bin <> ":" <> previous_path)

      workspace_root = Path.join(test_root, "workspaces")
      base_path = Path.join([test_root, "cache", "base"])
      worktree_root = Path.join(test_root, "worktrees")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        initialize_timeout_ms: 50,
        project_repository_url: "git@example.com:org/repo.git",
        project_default_branch: "main",
        project_source_strategy: "worktree",
        workspace_repository_base_root: base_path,
        workspace_worktree_base_root: worktree_root
      )

      assert {:error, {:workspace_hook_timeout, "project_bootstrap", 50, details}} =
               Workspace.create_for_issue("WT-INITIALIZE-TIMEOUT")

      assert details.elapsed_ms >= 50
      assert details.recent_output =~ "Receiving objects: fake slow clone"
    after
      System.put_env("PATH", previous_path)
      File.rm_rf(test_root)
    end
  end

  test "worktree bootstrap streams clone progress to progress recipient before command exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-progress-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH") || ""

    try do
      fake_bin = Path.join(test_root, "bin")
      File.mkdir_p!(fake_bin)

      fake_git = Path.join(fake_bin, "git")

      File.write!(fake_git, """
      #!/bin/sh
      echo "Receiving objects: 9% (32/355), 7.09 MiB | 23.00 KiB/s"
      sleep 1
      exit 0
      """)

      File.chmod!(fake_git, 0o755)
      System.put_env("PATH", fake_bin <> ":" <> previous_path)

      workspace_root = Path.join(test_root, "workspaces")
      base_path = Path.join([test_root, "cache", "base"])
      worktree_root = Path.join(test_root, "worktrees")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        initialize_timeout_ms: 50,
        project_repository_url: "git@example.com:org/repo.git",
        project_default_branch: "main",
        project_source_strategy: "worktree",
        workspace_repository_base_root: base_path,
        workspace_worktree_base_root: worktree_root
      )

      issue = %{id: "issue-worktree-progress", identifier: "WT-PROGRESS"}
      parent = self()
      task = Task.async(fn -> Workspace.create_for_issue(issue, nil, progress_recipient: parent) end)

      assert {:ok, progress} = receive_system_progress("issue-worktree-progress", "git_clone")
      assert progress.operation == "git_clone"
      assert progress.status == "running"
      assert progress.detail =~ "Receiving objects: 9%"

      assert {:error, {:workspace_hook_timeout, "project_bootstrap", 50, _details}} = Task.await(task, 2_000)
    after
      System.put_env("PATH", previous_path)
      File.rm_rf(test_root)
    end
  end

  test "workspace hook output is persisted while local hook is still running" do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    on_exit(fn ->
      if is_nil(previous_persistence) do
        Application.delete_env(:symphony_elixir, :persistence_module)
      else
        Application.put_env(:symphony_elixir, :persistence_module, previous_persistence)
      end
    end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-stream-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf 'stream-start\\n'; sleep 1; echo done > done.txt"
      )

      task = Task.async(fn -> Workspace.create_for_issue("MT-STREAM") end)
      workspace = Path.join(workspace_root, "MT-STREAM")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      done_path = Path.join(workspace, "done.txt")

      assert wait_until(fn ->
               output_event? =
                 FakePersistence.list_events(event_type: "workspace.hook_output")
                 |> Enum.any?(fn event -> to_string(get_in(event, [:payload, :output])) =~ "stream-start" end)

               output_event? and not File.exists?(done_path)
             end)

      assert {:ok, ^canonical_workspace} = Task.await(task, 2_000)

      event_types =
        FakePersistence.list_events()
        |> Enum.map(&Map.fetch!(&1, :event_type))

      assert "workspace.hook_started" in event_types
      assert "workspace.hook_output" in event_types
      assert "workspace.hook_completed" in event_types

      phase_events = FakePersistence.list_events(event_type: "run.phase")

      assert Enum.any?(phase_events, fn event ->
               get_in(event, [:payload, :phase]) == "workspace_after_create" and
                 get_in(event, [:payload, :status]) == "started"
             end)

      assert Enum.any?(phase_events, fn event ->
               get_in(event, [:payload, :phase]) == "workspace_after_create" and
                 get_in(event, [:payload, :status]) == "completed"
             end)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 2

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp receive_system_progress(issue_id, operation) do
    receive do
      {:system_worker_update, ^issue_id, %{operation: ^operation, status: "running"} = update} ->
        {:ok, update}

      {:system_worker_update, ^issue_id, _update} ->
        receive_system_progress(issue_id, operation)
    after
      1_000 -> :timeout
    end
  end

  defp repository_cache_path(base_root, repository_url, branch) do
    source = "#{repository_url}:#{branch}"
    digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    Path.join(base_root, "#{safe_identifier(Path.basename(repository_url, ".git"))}-#{digest}")
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "project", ~r/[^a-zA-Z0-9._-]/, "_")
  end
end

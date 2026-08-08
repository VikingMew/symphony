defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Orchestrator.DispatchPolicy

  defmodule EmptyIssueLinearClient do
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
  end

  defmodule NotifyingLinearClient do
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, configured_issues()}

    def fetch_candidate_issues do
      if test_pid = Application.get_env(:symphony_elixir, :linear_client_test_pid) do
        send(test_pid, :fetch_candidate_issues_called)
      end

      {:ok, configured_issues()}
    end

    def fetch_issues_by_states(_states) do
      if test_pid = Application.get_env(:symphony_elixir, :linear_client_test_pid) do
        send(test_pid, :fetch_terminal_issues_called)
      end

      {:ok, []}
    end

    defp configured_issues do
      Application.get_env(:symphony_elixir, :linear_client_test_issues, [])
    end
  end

  def run(issue, _recipient, _opts) do
    if test_pid = Application.get_env(:symphony_elixir, :agent_runner_test_pid) do
      send(test_pid, {:agent_runner_started, issue.id})
    end

    :ok
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"]
    assert config.tracker.terminal_states == ["Canceled", "Cancelled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "   ",
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "/bin/sh app-server",
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "definitely-not-valid",
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_thread_sandbox: "unsafe-ish",
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "workflow policy defaults and helpers classify task states" do
    config = Config.settings!()

    assert Config.workflow_profile_for_state("Refining") == "refinement"
    assert Config.workflow_profile_for_state("In Progress") == "implementation"
    assert Config.workflow_profile_for_state("Ready to Merge") == "merge"
    assert Config.workflow_profile_for_state("In Review") == nil
    assert Config.workflow_executor_for_state("Ready") == "codex_agent"
    assert Config.human_review_state?("In Review")
    refute Config.human_review_state?("In Progress")

    assert Config.workflow_allowed_updates("implementation")["target_states"] == [
             "In Progress",
             "In Review"
           ]

    assert get_in(config.workflow, ["tool_policy", "linear", "exposed_tools"]) == [
             "linear_task_read",
             "linear_task_update"
           ]

    assert get_in(config.workflow, ["tool_policy", "linear", "raw_graphql"]) == false
    assert get_in(config.profiles, ["implementation", "name"]) == "Implementation"
  end

  test "workflow policy supports state routing and validates transitions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{
        states: %{QA: %{profile: "qa"}},
        human_review_states: ["Product Review"],
        allowed_transitions: [%{from: "QA", to: "Done", actor: "codex", profile: "qa"}]
      },
      profiles_policy: %{
        qa: %{
          name: "QA",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend", template: "QA {{ issue.identifier }}"},
          allowed_updates: %{comment: true, result: true, target_states: ["Done"]}
        }
      }
    )

    assert Config.workflow_profile_for_state("QA") == "qa"
    assert Config.human_review_state?("Product Review")
    assert Config.workflow_allowed_updates("qa")["target_states"] == ["Done"]

    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{
        states: %{QA: %{profile: "qa"}},
        allowed_transitions: [%{from: "QA", to: "Done", actor: "robot"}]
      },
      profiles_policy: %{
        qa: %{
          name: "QA",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend", template: "QA {{ issue.identifier }}"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workflow"
    assert message =~ "allowed_transitions.actor"
  end

  test "workflow policy rejects target states and transitions outside configured state model" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Ready", "In Progress"],
      tracker_terminal_states: ["Done"],
      workflow_policy: %{
        states: %{Ready: %{profile: "implementation"}, "In Progress": %{profile: "implementation"}},
        human_review_states: ["In Review"],
        allowed_transitions: [%{from: "In Progress", to: "Unknown Review", actor: "codex", profile: "implementation"}]
      },
      profiles_policy: %{
        implementation: %{
          name: "Implementation",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend", template: "Implement {{ issue.identifier }}"},
          allowed_updates: %{comment: true, result: true, target_states: ["Unknown Review"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "allowed_transitions.to references unknown workflow state"
    assert message =~ "profiles.implementation.allowed_updates.target_states references unknown workflow state"
  end

  test "workflow policy accepts editable implementation review state from config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      tracker_active_states: ["Ready", "In Progress", "Ready to Merge", "Merging"],
      tracker_terminal_states: ["Done"],
      workflow_policy: %{
        states: %{
          Ready: %{profile: "implementation"},
          "In Progress": %{profile: "implementation"},
          "Ready to Merge": %{profile: "merge"},
          Merging: %{profile: "merge"}
        },
        human_review_states: ["In Review"],
        allowed_transitions: [
          %{from: "Ready", to: "In Progress", actor: "codex", profile: "implementation"},
          %{from: "In Progress", to: "In Review", actor: "codex", profile: "implementation"},
          %{from: "In Review", to: "Ready to Merge", actor: "human"},
          %{from: "In Review", to: "In Progress", actor: "human"},
          %{from: "Ready to Merge", to: "Merging", actor: "codex", profile: "merge"},
          %{from: "Merging", to: "Done", actor: "codex", profile: "merge"}
        ]
      },
      profiles_policy: %{
        implementation: %{
          name: "Implementation",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend", template: "Implement {{ issue.identifier }}"},
          allowed_updates: %{comment: true, result: true, target_states: ["In Progress", "In Review"]}
        },
        merge: %{
          name: "Merge",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend", template: "Merge {{ issue.identifier }}"},
          allowed_updates: %{comment: true, result: true, target_states: ["Merging", "Done"]}
        }
      }
    )

    assert :ok = Config.validate!()
    assert Config.human_review_state?("In Review")
    refute Config.human_review_state?("Needs Review")
    assert Config.workflow_allowed_updates("implementation")["target_states"] == ["In Progress", "In Review"]
  end

  test "workflow rejects nested profiles and profile active state routing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{
        profiles: %{qa: %{name: "QA"}},
        states: %{QA: %{profile: "qa"}}
      },
      profiles_policy: %{
        qa: %{
          name: "QA",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend", template: "QA {{ issue.identifier }}"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workflow.profiles is not supported"

    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{states: %{QA: %{profile: "qa"}}},
      profiles_policy: %{
        qa: %{
          name: "QA",
          active_states: ["QA"],
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend", template: "QA {{ issue.identifier }}"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "profiles.qa.active_states is not supported"
  end

  test "workflow validates executor prompt policy" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{states: %{Ready: %{profile: "implementation"}}},
      profiles_policy: %{
        implementation: %{
          name: "Implementation",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "disabled"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "profiles.implementation.prompt.mode cannot be disabled"

    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{states: %{Ready: %{profile: "implementation"}}},
      profiles_policy: %{
        implementation: %{
          name: "Implementation",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "append", template: "Legacy append"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "profiles.implementation.prompt.mode is invalid"

    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{states: %{Ready: %{profile: "implementation"}}},
      profiles_policy: %{
        implementation: %{
          name: "Implementation",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "extend"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "profiles.implementation.prompt.template must be a non-empty string for codex_agent extend mode"

    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_policy: %{states: %{Ready: %{profile: "implementation"}}},
      profiles_policy: %{
        implementation: %{
          name: "Implementation",
          executor: %{type: "codex_agent"},
          prompt: %{mode: "replace"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "profiles.implementation.prompt.template must be a non-empty string for codex_agent replace mode"
  end

  test "workflow supports manual profile executor" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      workflow_policy: %{states: %{"Ready to Merge" => %{profile: "merge"}}},
      profiles_policy: %{
        merge: %{
          name: "Merge",
          executor: %{type: "manual"},
          prompt: %{mode: "disabled"},
          allowed_updates: %{target_states: ["Done"]}
        }
      }
    )

    assert :ok = Config.validate!()
    assert Config.workflow_profile_for_state("Ready to Merge") == "merge"
    assert Config.workflow_executor_for_state("Ready to Merge") == "manual"
  end

  test "current split workflow package is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    refute Map.has_key?(hooks, "after_create")
    refute Map.has_key?(hooks, "before_remove")

    project = Map.get(config, "project", %{})
    assert Map.get(project, "repository_url") == "https://github.com/openai/symphony"

    assert Map.get(project, "setup_commands") == [
             "if command -v mise >/dev/null 2>&1; then mise trust && mise exec -- mix deps.get; fi"
           ]

    assert Map.get(project, "cleanup_commands") == [
             "mise exec -- mix workspace.before_remove"
           ]

    assert String.trim(prompt) != ""
  end

  test "workspace creation always recreates an existing local issue directory and reruns after_create" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-clean-workspace-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      counter_file = Path.join(test_root, "counter")
      workspace = Path.join(workspace_root, "MT-CLEAN")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf x >> #{counter_file}"
      )

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-CLEAN")
      File.write!(Path.join(workspace, "stale.txt"), "stale")

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-CLEAN")

      refute File.exists?(Path.join(workspace, "stale.txt"))
      assert File.read!(counter_file) == "xx"
    after
      File.rm_rf(test_root)
    end
  end

  test "project bootstrap runs before custom after_create hook" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-bootstrap-order-#{System.unique_integer([:positive])}")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-BOOT")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# cloned")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_repository_url: template_repo,
        project_setup_commands: ["printf setup > order"],
        hook_after_create: "test -f README.md && printf hook >> order"
      )

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-BOOT")

      assert File.exists?(Path.join(workspace, "README.md"))
      assert File.read!(Path.join(workspace, "order")) == "setuphook"
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace preparation recreates issue directory before reporting readiness" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-remote-clean-workspace-#{System.unique_integer([:positive])}")

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/workspaces/MT-REMOTE-CLEAN'
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        worker_ssh_hosts: ["worker-a"]
      )

      assert {:ok, "/remote/workspaces/MT-REMOTE-CLEAN"} =
               Workspace.create_for_issue("MT-REMOTE-CLEAN", "worker-a")

      trace = File.read!(trace_file)
      assert trace =~ ~s(rm -rf "$workspace")
      assert trace =~ ~s(mkdir -p "$workspace")
      refute trace =~ "created=0"
    after
      File.rm_rf(test_root)
    end
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server",
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server",
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "missing project repository url fails validation" do
    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: nil)

    assert {:error, :missing_project_repository_url} = Config.validate!()
  end

  test "missing project repository url prevents orchestrator polling" do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_test_pid = Application.get_env(:symphony_elixir, :linear_client_test_pid)

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: nil,
      poll_interval_ms: 5_000
    )

    Application.put_env(:symphony_elixir, :linear_client_module, NotifyingLinearClient)
    Application.put_env(:symphony_elixir, :linear_client_test_pid, self())

    orchestrator_name = Module.concat(__MODULE__, :MissingRepositoryUrlOrchestrator)

    {result, log} =
      with_log(fn ->
        Orchestrator.start_link(name: orchestrator_name)
      end)

    assert {:ok, pid} = result
    assert log =~ "Project repository URL missing in Project Settings"
    refute log =~ "Project repository URL missing in workflow config"
    refute log =~ ":missing_project_repository_url"

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:linear_client_test_pid, previous_test_pid)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    refute_receive :fetch_candidate_issues_called, 200
    refute_receive :fetch_terminal_issues_called, 200
  end

  test "rate-limit gate blocks dispatch when headroom is low and logs the block" do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_test_pid = Application.get_env(:symphony_elixir, :linear_client_test_pid)

    Application.put_env(:symphony_elixir, :linear_client_module, NotifyingLinearClient)
    Application.put_env(:symphony_elixir, :linear_client_test_pid, self())
    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: "git@example.com:org/repo.git")

    orchestrator_name = Module.concat(__MODULE__, :RateLimitGateBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:linear_client_test_pid, previous_test_pid)

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | listening_mode: :listening_all,
          codex_rate_limits: %{"primary" => %{"window_duration_mins" => 300, "used_percent" => 99}}
      }
    end)

    {snapshot, _log} =
      with_log(fn ->
        send(pid, :run_poll_cycle)
        refute_receive :fetch_candidate_issues_called, 100
        GenServer.call(pid, :snapshot)
      end)

    assert snapshot.running == []
    assert snapshot.rate_limit_gate.status == :blocked
    assert snapshot.rate_limit_gate.reason == :low_rate_limit_headroom
    assert :sys.get_state(pid).rate_limit_gate.reason == :low_rate_limit_headroom
  end

  test "run-start persistence failure prevents the agent task from starting" do
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_test_pid = Application.get_env(:symphony_elixir, :linear_client_test_pid)
    previous_test_issues = Application.get_env(:symphony_elixir, :linear_client_test_issues)
    previous_runner = Application.get_env(:symphony_elixir, :agent_runner_module)
    previous_runner_pid = Application.get_env(:symphony_elixir, :agent_runner_test_pid)
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:linear_client_test_pid, previous_test_pid)
      restore_app_env(:linear_client_test_issues, previous_test_issues)
      restore_app_env(:agent_runner_module, previous_runner)
      restore_app_env(:agent_runner_test_pid, previous_runner_pid)
      restore_app_env(:persistence_module, previous_persistence)

      if pid = Process.whereis(SymphonyElixir.Orchestrator), do: GenServer.stop(pid)

      if is_pid(orchestrator_pid) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    issue = %Issue{id: "issue-persistence", identifier: "MT-230", title: "Persistence prerequisite", state: "In Progress"}

    Application.put_env(:symphony_elixir, :linear_client_module, NotifyingLinearClient)
    Application.put_env(:symphony_elixir, :linear_client_test_pid, self())
    Application.put_env(:symphony_elixir, :linear_client_test_issues, [issue])
    Application.put_env(:symphony_elixir, :agent_runner_module, __MODULE__)
    Application.put_env(:symphony_elixir, :agent_runner_test_pid, self())
    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: "git@example.com:org/repo.git")

    {:ok, pid} = Orchestrator.start_link()
    Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.Persistence)
    refute Process.whereis(SymphonyElixir.Repo)

    log =
      capture_log(fn ->
        :sys.replace_state(pid, fn state ->
          %{state | listening_mode: :listening_all}
        end)

        send(pid, :run_poll_cycle)
        refute_receive {:agent_runner_started, "issue-persistence"}, 200
        _state = :sys.get_state(pid)
      end)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert state.retry_attempts["issue-persistence"].error =~ "run-start persistence failed"
    assert log =~ "operation=upsert_issue"
    assert log =~ "action=fail_task"
    assert log =~ "issue_id=\"issue-persistence\""
    assert log =~ "Run-start persistence failed action=skip_dispatch"
  end

  test "workflow file path defaults to workflow.yml in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "workflow.yml")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/workflow.yml"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts split workflow and profile-owned base prompt package" do
    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-split-workflow-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workflow_root)

      File.write!(Path.join(workflow_root, "workflow.yml"), """
      tracker:
        kind: linear
        project_slug: project
        active_states: ["Ready", "In Progress"]
        terminal_states: ["Done"]
      workflow:
        states:
          Ready:
            profile: implementation
      """)

      File.write!(Path.join(workflow_root, "profiles.yml"), """
      base_prompt: |
        Profile-owned base prompt body
      profiles:
        implementation:
          name: Implementation
          executor:
            type: codex_agent
          prompt:
            mode: extend
            template: Implement the task.
          allowed_updates:
            description: false
            comment: true
            result: true
            target_states: ["In Progress"]
      """)

      assert {:ok, workflow} = Workflow.load(Path.join(workflow_root, "workflow.yml"))
      assert get_in(workflow.config, ["tracker", "project_slug"]) == "project"
      assert get_in(workflow.config, ["workflow", "states", "Ready", "profile"]) == "implementation"
      assert get_in(workflow.config, ["profiles", "implementation", "name"]) == "Implementation"
      assert workflow.prompt == "Profile-owned base prompt body"
    after
      File.rm_rf(workflow_root)
    end
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.txt")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.txt")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      poll_interval_ms: 30_000,
      project_repository_url: "git@example.com:org/repo.git"
    )

    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "orchestrator starts when linear tracker configuration is incomplete" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: "",
      tracker_api_token: nil,
      tracker_project_slug: "",
      poll_interval_ms: 30_000
    )

    orchestrator_name = Module.concat(__MODULE__, :IncompleteLinearConfigOrchestrator)

    assert {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %Orchestrator.RunningIssue{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %Orchestrator.RunningIssue{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :linear_client_module, EmptyIssueLinearClient)

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:linear_client_module, previous_linear_client)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %Orchestrator.RunningIssue{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:listening_mode, :listening_all)
      end)

      send(pid, {:tick, initial_state.tick_token})
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:linear_client_module, previous_linear_client)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %Orchestrator.RunningIssue{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %Orchestrator.RunningIssue{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %Orchestrator.RunningIssue{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    scheduled_from_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_after(due_at_ms, scheduled_from_ms, 500, 2_000)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %Orchestrator.RunningIssue{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    scheduled_from_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent crashed: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_after(due_at_ms, scheduled_from_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %Orchestrator.RunningIssue{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    scheduled_from_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent crashed: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_after(due_at_ms, scheduled_from_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil,
      listening_mode: :listening_all
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "dispatch policy skips full ssh hosts under the shared per-host cap" do
    state = %Orchestrator.State{
      running: %{
        "issue-1" => %Orchestrator.RunningIssue{worker_host: "worker-a"}
      }
    }

    assert DispatchPolicy.select_worker_host(state, nil, worker_policy_settings(1)) == "worker-b"
  end

  test "dispatch policy returns no_worker_capacity when every ssh host is full" do
    state = %Orchestrator.State{
      running: %{
        "issue-1" => %Orchestrator.RunningIssue{worker_host: "worker-a"},
        "issue-2" => %Orchestrator.RunningIssue{worker_host: "worker-b"}
      }
    }

    assert DispatchPolicy.select_worker_host(state, nil, worker_policy_settings(1)) == :no_worker_capacity
  end

  test "dispatch policy keeps the preferred ssh host when it still has capacity" do
    state = %Orchestrator.State{
      running: %{
        "issue-1" => %Orchestrator.RunningIssue{worker_host: "worker-a"},
        "issue-2" => %Orchestrator.RunningIssue{worker_host: "worker-b"}
      }
    }

    assert DispatchPolicy.select_worker_host(state, "worker-a", worker_policy_settings(2)) == "worker-a"
  end

  defp worker_policy_settings(max_per_host) do
    %{
      ssh_hosts: ["worker-a", "worker-b"],
      max_concurrent_agents_per_host: max_per_host
    }
  end

  defp assert_due_after(due_at_ms, reference_ms, min_delay_ms, max_delay_ms) do
    delay_ms = due_at_ms - reference_ms

    assert delay_ms >= min_delay_ms
    assert delay_ms <= max_delay_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end
end

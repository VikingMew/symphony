# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.CoreTest.Sections.Core1 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import ExUnit.CaptureLog
      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Health
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.TestSupport.FakePersistence
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Worker.HeartbeatMetrics
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      defp restart_orchestrator_if_started(orchestrator_pid) do
        if is_pid(orchestrator_pid) do
          case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
        end
      end

      defp restart_orchestrator_if_stopped do
        if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
          case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
        end
      end

      import SymphonyElixir.TestSupport,
        only: [
          ensure_panel_children_running!: 0,
          panel_supervisor_running?: 0,
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      alias SymphonyElixir.CoreTest.{EmptyIssueLinearClient, NotifyingLinearClient}
      use SymphonyElixir.TestSupport
      alias SymphonyElixir.Orchestrator.DispatchPolicy

      defmodule Elixir.SymphonyElixir.CoreTest.EmptyIssueLinearClient do
        def fetch_issue_states_by_ids(_issue_ids) do
          {:ok, []}
        end

        def fetch_candidate_issues do
          {:ok, []}
        end

        def fetch_issues_by_states(_states) do
          {:ok, []}
        end
      end

      defmodule Elixir.SymphonyElixir.CoreTest.NotifyingLinearClient do
        def fetch_issue_states_by_ids(_issue_ids) do
          {:ok, configured_issues()}
        end

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
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: nil,
          tracker_project_slug: nil,
          poll_interval_ms: nil,
          tracker_active_states: nil,
          tracker_terminal_states: nil,
          codex_command: nil
        )

        config = Elixir.SymphonyElixir.Config.settings!()
        assert config.polling.interval_ms == 30_000
        assert config.tracker.active_states == ["Todo", "Ready", "In Progress"]
        assert config.tracker.terminal_states == ["Canceled", "Cancelled", "Duplicate", "Done"]
        assert config.tracker.assignee == nil
        assert config.agent.max_turns == 20

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          poll_interval_ms: "invalid"
        )

        assert_raise ArgumentError, ~r/interval_ms/, fn ->
          Elixir.SymphonyElixir.Config.settings!().polling.interval_ms
        end

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "polling.interval_ms"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          poll_interval_ms: 45_000
        )

        assert Elixir.SymphonyElixir.Config.settings!().polling.interval_ms == 45_000

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(), max_turns: 0)
        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "agent.max_turns"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(), max_turns: 5)
        assert Elixir.SymphonyElixir.Config.settings!().agent.max_turns == 5

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_active_states: "Todo,  Review,"
        )

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "tracker.active_states"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: "token",
          tracker_project_slug: nil
        )

        assert {:error, :missing_linear_project_slug} = Elixir.SymphonyElixir.Config.validate!()

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_project_slug: "project",
          codex_command: ""
        )

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "codex.command"
        assert message =~ "can't be blank"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          codex_command: "   ",
          project_repository_url: "git@example.com:org/repo.git"
        )

        assert :ok = Elixir.SymphonyElixir.Config.validate!()
        assert Elixir.SymphonyElixir.Config.settings!().codex.command == "   "

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          codex_command: "/bin/sh app-server",
          project_repository_url: "git@example.com:org/repo.git"
        )

        assert :ok = Elixir.SymphonyElixir.Config.validate!()

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          codex_approval_policy: "definitely-not-valid",
          project_repository_url: "git@example.com:org/repo.git"
        )

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "codex.approval_policy"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          codex_thread_sandbox: "unsafe-ish",
          project_repository_url: "git@example.com:org/repo.git"
        )

        assert :ok = Elixir.SymphonyElixir.Config.validate!()

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git",
          turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
        )

        assert :ok = Elixir.SymphonyElixir.Config.validate!()

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          codex_approval_policy: 123
        )

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "codex.approval_policy"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          codex_thread_sandbox: 123
        )

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "codex.thread_sandbox"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "123")
        assert {:error, {:unsupported_tracker_kind, "123"}} = Elixir.SymphonyElixir.Config.validate!()
      end

      test "workflow policy defaults and helpers classify task states" do
        config = Elixir.SymphonyElixir.Config.settings!()

        assert Elixir.SymphonyElixir.Config.workflow_profile_for_state("Refining") == "refinement"

        assert Elixir.SymphonyElixir.Config.workflow_profile_for_state("In Progress") ==
                 "implementation"

        assert Elixir.SymphonyElixir.Config.workflow_profile_for_state("Ready to Merge") == nil
        assert Elixir.SymphonyElixir.Config.workflow_executor_for_state("Ready") == "codex_agent"
        assert Elixir.SymphonyElixir.Config.human_review_state?("Ready to Merge")
        assert Elixir.SymphonyElixir.Config.human_review_state?("In Progress") == false

        assert Elixir.SymphonyElixir.Config.workflow_allowed_updates("implementation")["target_states"] ==
                 ["In Progress", "Ready to Merge"]

        assert get_in(config.workflow, ["tool_policy", "linear", "exposed_tools"]) == [
                 "linear_task_read",
                 "linear_task_update"
               ]

        assert get_in(config.workflow, ["tool_policy", "linear", "raw_graphql"]) == false

        assert get_in(config.workflow, ["tool_policy", "github", "exposed_tools"]) == [
                 "create_pull_request"
               ]

        assert get_in(config.workflow, ["tool_policy", "github", "profiles"]) == ["implementation"]
        assert get_in(config.profiles, ["implementation", "name"]) == "Implementation"

        transitions = get_in(config.workflow, ["allowed_transitions"])

        assert Enum.any?(
                 transitions,
                 &(&1["from"] == "Todo" and &1["to"] == "Refining" and &1["profile"] == "refinement")
               )

        assert Enum.any?(
                 transitions,
                 &(&1["from"] == "Refining" and &1["to"] == "Needs Refinement Review" and
                     &1["profile"] == "refinement")
               )

        refute Enum.any?(
                 transitions,
                 &(&1["from"] == "In Progress" and &1["to"] == "Needs Refinement Review")
               )
      end

      test "persisted workflow policy is ignored while profiles remain project-specific" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git",
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

        assert Elixir.SymphonyElixir.Config.workflow_profile_for_state("QA") == nil
        assert Elixir.SymphonyElixir.Config.human_review_state?("Product Review") == false
        assert Elixir.SymphonyElixir.Config.human_review_state?("Blocked")
        assert Elixir.SymphonyElixir.Config.workflow_allowed_updates("qa")["target_states"] == ["Done"]

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git",
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

        assert :ok = Elixir.SymphonyElixir.Config.validate!()
      end

      test "workflow ignores nested profiles but rejects profile active state routing" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git",
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

        assert :ok = Elixir.SymphonyElixir.Config.validate!()

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
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

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "profiles.qa.active_states is not supported"
      end

      test "workflow validates executor prompt policy" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
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

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "profiles.implementation.prompt.mode cannot be disabled"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
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

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()
        assert message =~ "profiles.implementation.prompt.mode is invalid"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
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

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()

        assert message =~
                 "profiles.implementation.prompt.template must be a non-empty string for codex_agent extend mode"

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
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

        assert {:error, {:invalid_workflow_config, message}} = Elixir.SymphonyElixir.Config.validate!()

        assert message =~
                 "profiles.implementation.prompt.template must be a non-empty string for codex_agent replace mode"
      end

      test "workflow supports manual profile executor" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git",
          workflow_policy: %{states: %{"Manual QA" => %{profile: "qa"}}},
          profiles_policy: %{
            qa: %{
              name: "QA",
              executor: %{type: "manual"},
              prompt: %{mode: "disabled"},
              allowed_updates: %{target_states: ["Done"]}
            }
          }
        )

        assert :ok = Elixir.SymphonyElixir.Config.validate!()
        assert Elixir.SymphonyElixir.Config.workflow_profile_for_state("Manual QA") == nil
        assert Elixir.SymphonyElixir.Config.workflow_profile("qa")["executor"]["type"] == "manual"
      end

      test "current split workflow package is valid and complete" do
        original_workflow_path = Elixir.SymphonyElixir.Workflow.workflow_file_path()
        on_exit(fn -> Elixir.SymphonyElixir.Workflow.set_workflow_file_path(original_workflow_path) end)
        Elixir.SymphonyElixir.Workflow.clear_workflow_file_path()

        assert {:ok, %{config: config, prompt: prompt}} = Elixir.SymphonyElixir.Workflow.load()
        assert is_map(config)

        tracker = Map.get(config, "tracker", %{})
        assert is_map(tracker)
        assert Map.get(tracker, "kind") == "linear"
        assert is_binary(Map.get(tracker, "project_slug"))
        assert is_list(Map.get(tracker, "active_states"))
        assert is_list(Map.get(tracker, "terminal_states"))

        hooks = Map.get(config, "hooks", %{})
        assert is_map(hooks)
        assert Map.has_key?(hooks, "after_create") == false
        assert Map.has_key?(hooks, "before_remove") == false

        project = Map.get(config, "project", %{})
        assert Map.get(project, "repository_url") == "https://github.com/openai/symphony"

        assert Map.get(project, "setup_commands") == [
                 "if command -v mise >/dev/null 2>&1; then mise trust && mise exec -- mix deps.get; fi"
               ]

        assert Map.get(project, "cleanup_commands") == ["mise exec -- mix workspace.before_remove"]

        assert String.trim(prompt) != ""
      end

      test "workspace creation always recreates an existing local issue directory and reruns after_create" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-clean-workspace-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")
          counter_file = Path.join(test_root, "counter")
          workspace = Path.join(workspace_root, "MT-CLEAN")

          File.mkdir_p!(workspace_root)

          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "printf x >> #{counter_file}"
          )

          assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

          assert {:ok, ^canonical_workspace} =
                   Elixir.SymphonyElixir.Workspace.create_for_issue("MT-CLEAN")

          File.write!(Path.join(workspace, "stale.txt"), "stale")

          assert {:ok, ^canonical_workspace} =
                   Elixir.SymphonyElixir.Workspace.create_for_issue("MT-CLEAN")

          assert File.exists?(Path.join(workspace, "stale.txt")) == false
          assert File.read!(counter_file) == "xx"
        after
          File.rm_rf(test_root)
        end
      end

      test "project bootstrap runs before custom after_create hook" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-bootstrap-order-#{System.unique_integer([:positive])}"
          )

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

          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            project_repository_url: template_repo,
            project_setup_commands: ["printf setup > order"],
            hook_after_create: "test -f README.md && printf hook >> order"
          )

          assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

          assert {:ok, ^canonical_workspace} =
                   Elixir.SymphonyElixir.Workspace.create_for_issue("MT-BOOT")

          assert File.exists?(Path.join(workspace, "README.md"))
          assert File.read!(Path.join(workspace, "order")) == "setuphook"
        after
          File.rm_rf(test_root)
        end
      end

      test "remote workspace preparation recreates issue directory before reporting readiness" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-remote-clean-workspace-#{System.unique_integer([:positive])}"
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

          File.mkdir_p!(test_root)
          System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
          System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

          File.write!(
            fake_ssh,
            "#!/bin/sh\ntrace_file=\"${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}\"\nprintf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"\nprintf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/workspaces/MT-REMOTE-CLEAN'\n"
          )

          File.chmod!(fake_ssh, 493)

          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: "/remote/workspaces",
            worker_ssh_hosts: ["worker-a"]
          )

          assert {:ok, "/remote/workspaces/MT-REMOTE-CLEAN"} =
                   Elixir.SymphonyElixir.Workspace.create_for_issue("MT-REMOTE-CLEAN", "worker-a")

          trace = File.read!(trace_file)
          assert trace =~ ~s(rm -rf "$workspace")
          assert trace =~ ~s(mkdir -p "$workspace")
        after
          File.rm_rf(test_root)
        end
      end

      test "linear api token resolves from LINEAR_API_KEY env var" do
        previous_linear_api_key = System.get_env("LINEAR_API_KEY")
        env_api_key = "test-linear-api-key"

        on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
        System.put_env("LINEAR_API_KEY", env_api_key)

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: nil,
          tracker_project_slug: "project",
          codex_command: "/bin/sh app-server",
          project_repository_url: "git@example.com:org/repo.git"
        )

        assert Elixir.SymphonyElixir.Config.settings!().tracker.api_key == env_api_key
        assert Elixir.SymphonyElixir.Config.settings!().tracker.project_slug == "project"
        assert :ok = Elixir.SymphonyElixir.Config.validate!()
      end

      test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
        previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
        env_assignee = "dev@example.com"

        on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
        System.put_env("LINEAR_ASSIGNEE", env_assignee)

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_assignee: nil,
          tracker_project_slug: "project",
          codex_command: "/bin/sh app-server",
          project_repository_url: "git@example.com:org/repo.git"
        )

        assert Elixir.SymphonyElixir.Config.settings!().tracker.assignee == env_assignee
      end

      test "missing project repository url fails validation" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: nil
        )

        assert {:error, :missing_project_repository_url} = Elixir.SymphonyElixir.Config.validate!()
      end

      test "missing project repository url prevents orchestrator polling" do
        previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
        previous_test_pid = Application.get_env(:symphony_elixir, :linear_client_test_pid)

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: nil,
          poll_interval_ms: 5000
        )

        Application.put_env(
          :symphony_elixir,
          :linear_client_module,
          Elixir.SymphonyElixir.CoreTest.NotifyingLinearClient
        )

        Application.put_env(:symphony_elixir, :linear_client_test_pid, self())

        orchestrator_name = Module.concat(__MODULE__, :MissingRepositoryUrlOrchestrator)

        {result, log} =
          with_log(fn ->
            Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)
          end)

        assert {:ok, pid} = result
        assert log =~ "Project repository URL missing in Project Settings"

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

        Application.put_env(
          :symphony_elixir,
          :linear_client_module,
          Elixir.SymphonyElixir.CoreTest.NotifyingLinearClient
        )

        Application.put_env(:symphony_elixir, :linear_client_test_pid, self())

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_name = Module.concat(__MODULE__, :RateLimitGateBlockOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          restore_app_env(:linear_client_module, previous_linear_client)
          restore_app_env(:linear_client_test_pid, previous_test_pid)

          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
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
        assert snapshot.rate_limit_gate == %{status: :project_scoped, reason: :project_scoped}
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
          assert :ok =
                   Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
        end

        on_exit(fn ->
          restore_app_env(:linear_client_module, previous_linear_client)
          restore_app_env(:linear_client_test_pid, previous_test_pid)
          restore_app_env(:linear_client_test_issues, previous_test_issues)
          restore_app_env(:agent_runner_module, previous_runner)
          restore_app_env(:agent_runner_test_pid, previous_runner_pid)
          restore_app_env(:persistence_module, previous_persistence)

          stop_registered_orchestrator()

          restart_orchestrator_if_started(orchestrator_pid)
        end)

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: "issue-persistence",
          identifier: "MT-230",
          title: "Persistence prerequisite",
          state: "In Progress"
        }

        Application.put_env(
          :symphony_elixir,
          :linear_client_module,
          Elixir.SymphonyElixir.CoreTest.NotifyingLinearClient
        )

        Application.put_env(:symphony_elixir, :linear_client_test_pid, self())
        Application.put_env(:symphony_elixir, :linear_client_test_issues, [issue])
        Application.put_env(:symphony_elixir, :agent_runner_module, __MODULE__)
        Application.put_env(:symphony_elixir, :agent_runner_test_pid, self())

        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link()
        Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.Persistence)
        assert Process.whereis(SymphonyElixir.Repo) == nil

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

      test "workflow file path defaults to the checked-in example when app env is unset" do
        original_workflow_path = Elixir.SymphonyElixir.Workflow.workflow_file_path()

        on_exit(fn ->
          Elixir.SymphonyElixir.Workflow.set_workflow_file_path(original_workflow_path)
        end)

        Elixir.SymphonyElixir.Workflow.clear_workflow_file_path()

        assert Elixir.SymphonyElixir.Workflow.workflow_file_path() ==
                 Path.join([File.cwd!(), "docs", "examples", "workflow.yml"])
      end

      test "workflow file path resolves from app env when set" do
        app_workflow_path = "/tmp/app/workflow.yml"

        on_exit(fn ->
          Elixir.SymphonyElixir.Workflow.clear_workflow_file_path()
        end)

        Elixir.SymphonyElixir.Workflow.set_workflow_file_path(app_workflow_path)

        assert Elixir.SymphonyElixir.Workflow.workflow_file_path() == app_workflow_path
      end

      test "workflow load accepts split workflow and profile-owned base prompt package" do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-split-workflow-#{System.unique_integer([:positive])}"
          )

        try do
          File.mkdir_p!(workflow_root)

          File.write!(
            Path.join(workflow_root, "workflow.yml"),
            "tracker:\n  kind: linear\n  project_slug: project\n  active_states: [\"Ready\", \"In Progress\"]\n  terminal_states: [\"Done\"]\nworkflow:\n  states:\n    Ready:\n      profile: implementation\n"
          )

          File.write!(
            Path.join(workflow_root, "profiles.yml"),
            "base_prompt: |\n  Profile-owned base prompt body\nprofiles:\n  implementation:\n    name: Implementation\n    executor:\n      type: codex_agent\n    prompt:\n      mode: extend\n      template: Implement the task.\n    allowed_updates:\n      description: false\n      comment: true\n      result: true\n      target_states: [\"In Progress\"]\n"
          )

          assert {:ok, workflow} =
                   Elixir.SymphonyElixir.Workflow.load(Path.join(workflow_root, "workflow.yml"))

          assert get_in(workflow.config, ["tracker", "project_slug"]) == "project"
          assert get_in(workflow.config, ["workflow", "states", "Ready", "profile"]) == "implementation"
          assert get_in(workflow.config, ["profiles", "implementation", "name"]) == "Implementation"
          assert workflow.prompt == "Profile-owned base prompt body"
        after
          File.rm_rf(workflow_root)
        end
      end
    end
  end
end

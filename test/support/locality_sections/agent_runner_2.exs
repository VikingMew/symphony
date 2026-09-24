# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.AgentRunnerTest.Sections.AgentRunner2 do
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

      import SymphonyElixir.TestSupport,
        only: [
          ensure_panel_children_running!: 0,
          panel_supervisor_running?: 0,
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
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
            "#!/bin/sh\ntrace_file=\"${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}\"\nprintf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"\n\ncase \"$*\" in\n  *worker-a*\"__SYMPHONY_WORKSPACE__\"*)\n    printf '%s\\n' 'worker-a prepare failed' >&2\n    exit 75\n    ;;\n  *worker-b*\"__SYMPHONY_WORKSPACE__\"*)\n    printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'\n    exit 0\n    ;;\n  *)\n    exit 0\n    ;;\nesac\n"
          )

          File.chmod!(fake_ssh, 493)

          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: "~/.symphony-remote-workspaces",
            worker_ssh_hosts: ["worker-a", "worker-b"]
          )

          issue = %Elixir.SymphonyElixir.Linear.Issue{
            id: "issue-ssh-failover",
            identifier: "MT-SSH-FAILOVER",
            title: "Do not fail over within a single worker run",
            description: "Surface the startup failure to the orchestrator",
            state: "In Progress"
          }

          assert {:failed, {:workspace_prepare_failed, "worker-a", 75, "worker-a prepare failed\n"}} =
                   Elixir.SymphonyElixir.AgentRunner.run(issue, nil, worker_host: "worker-a")

          trace = File.read!(trace_file)
          assert trace =~ "worker-a bash -lc"
        after
          File.rm_rf(test_root)
        end
      end

      test "agent runner continues with a follow-up turn while the issue remains active" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
          )

        try do
          template_repo = Path.join(test_root, "source")
          workspace_root = Path.join(test_root, "workspaces")
          codex_binary = Path.join(test_root, "fake-codex")
          trace_file = Path.join(test_root, "codex.trace")

          File.mkdir_p!(template_repo)
          File.write!(Path.join(template_repo, "README.md"), "# test")
          System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
          System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", template_repo, "add", "README.md"])
          System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

          File.write!(
            codex_binary,
            "#!/bin/sh\ntrace_file=\"${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}\"\nrun_id=\"$(date +%s%N)-$$\"\nprintf 'RUN:%s\\n' \"$run_id\" >> \"$trace_file\"\ncount=0\n\nwhile IFS= read -r line; do\n  count=$((count + 1))\n  printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"\n  case \"$count\" in\n    1)\n      printf '%s\\n' '{\"id\":1,\"result\":{}}'\n      ;;\n    2)\n      ;;\n    3)\n      printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-cont\"}}}'\n      ;;\n    4)\n      printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-cont-1\"}}}'\n      printf '%s\\n' '{\"method\":\"turn/completed\"}'\n      ;;\n    5)\n      printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-cont-2\"}}}'\n      printf '%s\\n' '{\"method\":\"turn/completed\"}'\n      ;;\n  esac\ndone\n"
          )

          File.chmod!(codex_binary, 493)
          System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

          on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
            codex_command: "#{codex_binary} app-server",
            max_turns: 3
          )

          parent = self()

          state_fetcher = fn [_issue_id] ->
            attempt = Process.get(:agent_turn_fetch_count, 0) + 1
            Process.put(:agent_turn_fetch_count, attempt)
            send(parent, {:issue_state_fetch, attempt})

            state =
              if attempt == 1 do
                "In Progress"
              else
                "Done"
              end

            {:ok,
             [
               %Elixir.SymphonyElixir.Linear.Issue{
                 id: "issue-continue",
                 identifier: "MT-247",
                 title: "Continue until done",
                 description: "Still active after first turn",
                 state: state
               }
             ]}
          end

          issue = %Elixir.SymphonyElixir.Linear.Issue{
            id: "issue-continue",
            identifier: "MT-247",
            title: "Continue until done",
            description: "Still active after first turn",
            state: "In Progress",
            url: "https://example.org/issues/MT-247",
            labels: []
          }

          assert :success =
                   Elixir.SymphonyElixir.AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

          assert_receive {:issue_state_fetch, 1}
          assert_receive {:issue_state_fetch, 2}

          lines = File.read!(trace_file) |> String.split("\n", trim: true)

          assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
          assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

          turn_texts =
            lines
            |> Enum.filter(&String.starts_with?(&1, "JSON:"))
            |> Enum.map(&String.trim_leading(&1, "JSON:"))
            |> Enum.map(&Jason.decode!/1)
            |> Enum.filter(&(&1["method"] == "turn/start"))
            |> Enum.map(fn payload ->
              get_in(payload, ["params", "input"])
              |> Enum.map_join("\n", &Map.get(&1, "text", ""))
            end)

          assert length(turn_texts) == 2
          assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
          assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
          assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
        after
          System.delete_env("SYMP_TEST_CODEx_TRACE")
          File.rm_rf(test_root)
        end
      end

      test "agent runner stops continuing once agent.max_turns is reached" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
          )

        try do
          template_repo = Path.join(test_root, "source")
          workspace_root = Path.join(test_root, "workspaces")
          codex_binary = Path.join(test_root, "fake-codex")
          trace_file = Path.join(test_root, "codex.trace")

          File.mkdir_p!(template_repo)
          File.write!(Path.join(template_repo, "README.md"), "# test")
          System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
          System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", template_repo, "add", "README.md"])
          System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

          File.write!(
            codex_binary,
            "#!/bin/sh\ntrace_file=\"${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}\"\nprintf 'RUN\\n' >> \"$trace_file\"\ncount=0\n\nwhile IFS= read -r line; do\n  count=$((count + 1))\n  printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"\n  case \"$count\" in\n    1)\n      printf '%s\\n' '{\"id\":1,\"result\":{}}'\n      ;;\n    2)\n      ;;\n    3)\n      printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-max\"}}}'\n      ;;\n    4)\n      printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-max-1\"}}}'\n      printf '%s\\n' '{\"method\":\"turn/completed\"}'\n      ;;\n    5)\n      printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-max-2\"}}}'\n      printf '%s\\n' '{\"method\":\"turn/completed\"}'\n      ;;\n  esac\ndone\n"
          )

          File.chmod!(codex_binary, 493)
          System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

          on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
            codex_command: "#{codex_binary} app-server",
            max_turns: 2
          )

          state_fetcher = fn [_issue_id] ->
            {:ok,
             [
               %Elixir.SymphonyElixir.Linear.Issue{
                 id: "issue-max-turns",
                 identifier: "MT-248",
                 title: "Stop at max turns",
                 description: "Still active",
                 state: "In Progress"
               }
             ]}
          end

          issue = %Elixir.SymphonyElixir.Linear.Issue{
            id: "issue-max-turns",
            identifier: "MT-248",
            title: "Stop at max turns",
            description: "Still active",
            state: "In Progress",
            url: "https://example.org/issues/MT-248",
            labels: []
          }

          assert :success =
                   Elixir.SymphonyElixir.AgentRunner.run(issue, nil,
                     issue_state_fetcher: state_fetcher,
                     pull_request_ensurer: fn _issue, _project, _opts ->
                       flunk("max-turn exhaustion must not create a pull request")
                     end
                   )

          trace = File.read!(trace_file)
          assert length(String.split(trace, "RUN", trim: true)) == 1
          assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
        after
          System.delete_env("SYMP_TEST_CODEx_TRACE")
          File.rm_rf(test_root)
        end
      end

      test "explicit implementation completion ensures the PR before the Linear transition" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-handoff-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")
          workspace = Path.join(workspace_root, "SYM-1")
          codex_binary = Path.join(test_root, "fake-codex")

          File.mkdir_p!(workspace)

          File.write!(
            codex_binary,
            "#!/bin/sh\ncount=0\nwhile IFS= read -r line; do\n  count=$((count + 1))\n  case \"$count\" in\n    1)\n      printf '%s\n' '{\"id\":1,\"result\":{}}'\n      ;;\n    2)\n      ;;\n    3)\n      printf '%s\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-handoff\"}}}'\n      ;;\n    4)\n      printf '%s\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-handoff\"}}}'\n      printf '%s\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"create_pull_request\",\"callId\":\"call-pr\",\"threadId\":\"thread-handoff\",\"turnId\":\"turn-handoff\",\"arguments\":{\"title\":\"SYM-1: Ship PR handoff\",\"body\":\"#### Summary\\n\\n- handoff\\n\\n#### Test Plan\\n\\n- [x] green\\n\\nFixes SYM-1\"}}}'\n      ;;\n    5)\n      printf '%s\n' '{\"id\":104,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_task_update\",\"callId\":\"call-handoff\",\"threadId\":\"thread-handoff\",\"turnId\":\"turn-handoff\",\"arguments\":{\"target_state\":\"Ready to Merge\",\"comment\":\"Completed: handoff; Validation: green; Deviations: None; Blockers: None\",\"result\":{\"completed\":\"handoff\",\"validation\":\"green\",\"deviations\":\"None\",\"blockers\":\"\"},\"references\":{\"branch\":\"feature/sym-1\",\"pr_url\":\"https://github.com/acme/app/pull/12\",\"pr_proof\":\"mbVD7FCl1tUnIpKyIE21xrXoJLPxt9GYsaU1d6gbm6U\"}}}}'\n      ;;\n    6)\n      printf '%s\n' '{\"method\":\"turn/completed\"}'\n      exit 0\n      ;;\n  esac\ndone\n"
          )

          File.chmod!(codex_binary, 493)

          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            project_repository_url: "https://github.com/acme/app",
            codex_command: "#{codex_binary} app-server"
          )

          issue = %Elixir.SymphonyElixir.Linear.Issue{
            id: "issue-handoff",
            identifier: "SYM-1",
            title: "Ship PR handoff",
            description: "Ensure the PR before changing Linear",
            state: "In Progress",
            branch_name: "feature/sym-1",
            labels: []
          }

          test_pid = self()

          pull_request_ensurer = fn handoff_issue, project, rendered, github_opts ->
            send(test_pid, {:handoff_order, :pr})
            assert handoff_issue.branch_name == "feature/sym-1"
            assert project.repository_url == "https://github.com/acme/app"
            assert github_opts == []
            assert rendered.title == "SYM-1: Ship PR handoff"
            assert rendered.body =~ "#### Summary\n\n- handoff"
            assert rendered.body =~ "#### Test Plan\n\n- [x] green"
            assert rendered.body =~ "\n\nFixes SYM-1"

            {:ok,
             %{
               url: "https://github.com/acme/app/pull/12",
               repository: "acme/app",
               base: "main",
               head: "feature/sym-1",
               source: :gh
             }}
          end

          graphql = fn query, variables ->
            cond do
              query =~ "attachmentCreate" ->
                send(test_pid, {:handoff_order, :attachment})
                assert variables["input"]["url"] == "https://github.com/acme/app/pull/12"
                {:ok, %{"data" => %{"attachmentCreate" => %{"success" => true}}}}

              query =~ "commentCreate" ->
                send(test_pid, {:handoff_order, :comment})
                {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

              query =~ "SymphonyLinearIssueTeamStates" ->
                send(test_pid, {:handoff_order, :state_lookup})

                {:ok,
                 %{
                   "data" => %{
                     "issue" => %{
                       "team" => %{
                         "states" => %{
                           "nodes" => [%{"id" => "state-ready-to-merge", "name" => "Ready to Merge"}]
                         }
                       }
                     }
                   }
                 }}

              query =~ "SymphonyLinearTaskIssueUpdate" ->
                send(test_pid, {:handoff_order, :state_update})
                assert variables["input"]["stateId"] == "state-ready-to-merge"
                {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
            end
          end

          assert :success =
                   Elixir.SymphonyElixir.AgentRunner.run(issue, nil,
                     workspace_creator: fn ^issue, nil, _opts -> {:ok, workspace} end,
                     implementation_branch_checkout: fn ^workspace, "feature/sym-1", _opts ->
                       {:ok, "checked out"}
                     end,
                     pull_request_ensurer: pull_request_ensurer,
                     dynamic_tool_opts: [graphql: graphql, pull_request_proof_secret: "test-proof"],
                     issue_state_fetcher: fn ["issue-handoff"] ->
                       {:ok, [%{issue | state: "Ready to Merge"}]}
                     end,
                     run_id: "run-handoff"
                   )

          assert_receive {:handoff_order, :pr}
          assert_receive {:handoff_order, :attachment}
          assert_receive {:handoff_order, :comment}
          assert_receive {:handoff_order, :state_lookup}
          assert_receive {:handoff_order, :state_update}

          events =
            Elixir.SymphonyElixir.TestSupport.FakePersistence.list_events(
              issue_identifier: "SYM-1",
              event_type: "run.phase"
            )
            |> Enum.filter(&(&1.payload.phase == "implementation_handoff"))

          assert Enum.map(events, & &1.payload.status) == ["completed", "started"]
          assert Enum.all?(events, &(&1.run_id == "run-handoff"))
          assert Enum.all?(events, &(&1.payload.session_id == "thread-handoff-turn-handoff"))
          assert List.first(events).payload.url == "https://github.com/acme/app/pull/12"

          audits =
            Elixir.SymphonyElixir.TestSupport.FakePersistence.list_events(
              issue_identifier: "SYM-1",
              event_type: "linear.tool_call"
            )

          assert Enum.map(audits, & &1.payload.tool) |> Enum.sort() == [
                   "create_pull_request",
                   "linear_task_update"
                 ]

          audit = Enum.find(audits, &(&1.payload.tool == "linear_task_update"))
          assert audit.run_id == "run-handoff"
          assert audit.payload.status == "success"
        after
          File.rm_rf(test_root)
        end
      end
    end
  end
end

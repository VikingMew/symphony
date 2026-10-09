# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.AgentRunner1 do
  @moduledoc false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Workflow

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      use SymphonyElixir.TestSupport

      test "normalizes explicit terminal outcomes without inspecting blocker reason" do
        blocked = %{
          reason: "blocked_on_push_auth",
          detail: "refresh credentials",
          references: %{remote: "origin"}
        }

        assert AgentRunner.normalize_outcome(:ok) == :success
        assert AgentRunner.normalize_outcome({:blocked, blocked}) == {:blocked, blocked}
        assert AgentRunner.normalize_outcome({:error, :boom}) == {:failed, :boom}

        assert AgentRunner.normalize_outcome(%{reason: "looks blocked"}) ==
                 {:failed, {:invalid_agent_outcome, %{reason: "looks blocked"}}}
      end

      test "builds canonical operator task identities" do
        assert AgentRunner.operator_task_identity(:nap, "operator-123") == %{
                 identifier: "NAP-operator-123",
                 label: "Nap",
                 description: "Audit project context and create focused backlog issues without modifying the repository."
               }

        assert AgentRunner.operator_task_identity(:day_dreaming, "operator-123") == %{
                 identifier: "DAY-DREAMING-operator-123",
                 label: "Day dreaming",
                 description: "Explore project direction and create focused product discovery backlog issues without modifying the repository."
               }
      end

      test "operator runner carries the selected project into workspace preparation" do
        test_pid = self()

        workspace_creator = fn issue, worker_host, opts ->
          send(test_pid, {:operator_workspace_requested, issue, worker_host, opts})
          {:error, :stop_after_workspace_assertion}
        end

        assert {:error, :stop_after_workspace_assertion} =
                 AgentRunner.run_operator(:nap, "operator-project", nil,
                   project_id: "project-123",
                   workspace_creator: workspace_creator
                 )

        assert_receive {:operator_workspace_requested, %Issue{} = issue, nil, workspace_opts}
        assert issue.id == "operator-project"
        assert issue.identifier == AgentRunner.operator_task_identity(:nap, "operator-project").identifier
        assert Keyword.fetch!(workspace_opts, :project_id) == "project-123"
      end

      test "agent runner keeps workspace after successful codex run" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
          )

        try do
          template_repo = Path.join(test_root, "source")
          workspace_root = Path.join(test_root, "workspaces")
          codex_binary = Path.join(test_root, "fake-codex")

          File.mkdir_p!(template_repo)
          File.mkdir_p!(workspace_root)
          File.write!(Path.join(template_repo, "README.md"), "# test")
          System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
          System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", template_repo, "add", "README.md"])
          System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

          File.write!(codex_binary, """
          #!/bin/sh
          count=0
          while IFS= read -r line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{\"id\":1,\"result\":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
                ;;
              4)
                printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
                printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"status\":\"completed\"}}}'
                exit 0
                ;;
              *)
                ;;
            esac
          done
          """)

          File.chmod!(codex_binary, 0o755)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
            codex_command: "#{codex_binary} app-server"
          )

          issue = %Issue{
            identifier: "S-99",
            title: "Smoke test",
            description: "Run and keep workspace",
            state: "In Progress",
            url: "https://example.org/issues/S-99",
            labels: ["backend"]
          }

          before = MapSet.new(File.ls!(workspace_root))
          assert :success = AgentRunner.run(issue)
          entries_after = MapSet.new(File.ls!(workspace_root))

          created =
            MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

          created = MapSet.new(created)

          assert MapSet.size(created) == 1
          workspace_name = created |> Enum.to_list() |> List.first()
          assert workspace_name == "S-99"

          workspace = Path.join(workspace_root, workspace_name)
          assert File.exists?(workspace)
          assert File.exists?(Path.join(workspace, "README.md"))
        after
          File.rm_rf(test_root)
        end
      end

      test "agent runner forwards timestamped codex updates to recipient" do
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

        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
          )

        try do
          template_repo = Path.join(test_root, "source")
          workspace_root = Path.join(test_root, "workspaces")
          codex_binary = Path.join(test_root, "fake-codex")

          File.mkdir_p!(template_repo)
          File.write!(Path.join(template_repo, "README.md"), "# test")
          System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
          System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", template_repo, "add", "README.md"])
          System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

          File.write!(
            codex_binary,
            """
            #!/bin/sh
            count=0
            while IFS= read -r line; do
              count=$((count + 1))
              case "$count" in
                1)
                  printf '%s\\n' '{\"id\":1,\"result\":{}}'
                  ;;
                2)
                  printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
                  ;;
                3)
                  printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
                  ;;
                4)
                  printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"status\":\"completed\"}}}'
                  ;;
                *)
                  ;;
              esac
            done
            """
          )

          File.chmod!(codex_binary, 0o755)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
            codex_command: "#{codex_binary} app-server"
          )

          issue = %Issue{
            id: "issue-live-updates",
            identifier: "MT-99",
            title: "Smoke test",
            description: "Capture codex updates",
            state: "In Progress",
            url: "https://example.org/issues/MT-99",
            labels: ["backend"]
          }

          test_pid = self()

          assert :success =
                   AgentRunner.run(
                     issue,
                     test_pid,
                     issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
                   )

          assert_receive {:codex_worker_update, "issue-live-updates",
                          %{
                            event: :session_started,
                            timestamp: %DateTime{},
                            session_id: session_id
                          }},
                         500

          assert session_id == "thread-live-turn-live"

          phase_pairs =
            FakePersistence.list_events(event_type: "run.phase")
            |> Enum.map(fn event -> {get_in(event, [:payload, :phase]), get_in(event, [:payload, :status])} end)

          assert {"workspace_preparing", "started"} in phase_pairs
          assert {"workspace_preparing", "completed"} in phase_pairs
          assert {"codex_starting", "started"} in phase_pairs
          assert {"codex_starting", "completed"} in phase_pairs
          assert {"codex_running", "started"} in phase_pairs
          assert {"codex_running", "completed"} in phase_pairs
        after
          File.rm_rf(test_root)
        end
      end

      test "agent runner moves ready implementation issue to in progress after codex starts and before first turn" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-ready-transition-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")
          codex_binary = Path.join(test_root, "fake-codex")
          trace_file = Path.join(test_root, "codex.trace")

          File.mkdir_p!(test_root)

          File.write!(codex_binary, """
          #!/bin/sh
          trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/symphony-ready-transition.trace}"
          count=0
          while IFS= read -r line; do
            count=$((count + 1))
            printf 'LINE%s:%s\\n' "$count" "$line" >> "$trace_file"
            case "$count" in
              1)
                printf '%s\\n' '{\"id\":1,\"result\":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-ready\"}}}'
                ;;
              4)
                printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-ready\"}}}'
                printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"status\":\"completed\"}}}'
                exit 0
                ;;
              *)
                ;;
            esac
          done
          """)

          File.chmod!(codex_binary, 0o755)

          previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

          on_exit(fn ->
            restore_env("SYMP_TEST_CODEX_TRACE", previous_trace)
          end)

          System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "printf ready > README.md",
            codex_command: "#{codex_binary} app-server",
            prompt: "Current status: {{ issue.state }}"
          )

          issue = %Issue{
            id: "issue-ready-transition",
            identifier: "MT-READY",
            title: "Start implementation",
            description: "Move after Codex startup",
            state: "Ready",
            url: "https://example.org/issues/MT-READY",
            labels: []
          }

          test_pid = self()

          transitioner = fn transition_issue, target_state ->
            assert transition_issue.id == "issue-ready-transition"
            assert transition_issue.state == "Ready"
            assert target_state == "In Progress"
            assert File.read!(trace_file) =~ "thread/start"
            send(test_pid, {:implementation_started, target_state})
            :ok
          end

          assert :success =
                   AgentRunner.run(issue, nil,
                     implementation_start_transitioner: transitioner,
                     issue_state_fetcher: fn ["issue-ready-transition"] -> {:ok, [%{issue | state: "Done"}]} end
                   )

          assert_receive {:implementation_started, "In Progress"}

          trace = File.read!(trace_file)
          assert trace =~ "Current status: In Progress"
        after
          File.rm_rf(test_root)
        end
      end

      test "agent runner does not move ready issue when codex startup fails" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-ready-startup-failure-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")
          codex_binary = Path.join(test_root, "fake-codex")

          File.mkdir_p!(test_root)

          File.write!(codex_binary, """
          #!/bin/sh
          printf '%s\\n' 'codex startup failed' >&2
          exit 127
          """)

          File.chmod!(codex_binary, 0o755)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "printf ready > README.md",
            codex_command: "#{codex_binary} app-server"
          )

          issue = %Issue{
            id: "issue-ready-startup-failure",
            identifier: "MT-READY-FAIL",
            title: "Startup failure",
            description: "Do not transition",
            state: "Ready",
            url: "https://example.org/issues/MT-READY-FAIL",
            labels: []
          }

          transitioner = fn _transition_issue, _target_state ->
            # docs/negative-assertion-audit.md control-flow contract: fail explicitly if this branch is reached.
            flunk("Ready issue should not transition when Codex startup fails")
          end

          assert {:failed, {:codex_startup_failed, _details}} =
                   AgentRunner.run(issue, nil, implementation_start_transitioner: transitioner)
        after
          File.rm_rf(test_root)
        end
      end

      test "agent runner refreshes a Todo issue in Refining before the first turn" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-refinement-transition-#{System.unique_integer([:positive])}"
          )

        try do
          workspace = Path.join(test_root, "workspace")
          codex_binary = Path.join(test_root, "fake-codex")
          trace_file = Path.join(test_root, "codex.trace")

          File.mkdir_p!(workspace)

          File.write!(codex_binary, """
          #!/bin/sh
          trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/symphony-refinement-transition.trace}"
          count=0
          while IFS= read -r line; do
            count=$((count + 1))
            printf 'LINE%s:%s\\n' "$count" "$line" >> "$trace_file"
            case "$count" in
              1) printf '%s\\n' '{"id":1,"result":{}}' ;;
              3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-refinement"}}}' ;;
              4)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-refinement"}}}'
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
                exit 0
                ;;
            esac
          done
          """)

          File.chmod!(codex_binary, 0o755)
          previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")
          on_exit(fn -> restore_env("SYMP_TEST_CODEX_TRACE", previous_trace) end)
          System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: test_root,
            codex_command: "#{codex_binary} app-server",
            prompt: "Current status: {{ issue.state }}"
          )

          issue = %Issue{
            id: "issue-refinement-transition",
            identifier: "MT-REFINE",
            title: "Start refinement",
            description: "Refresh before Codex",
            state: "Todo",
            labels: []
          }

          test_pid = self()

          transitioner = fn transition_issue, target_state ->
            assert transition_issue.state == "Todo"
            assert target_state == "Refining"
            send(test_pid, :refinement_started)
            :ok
          end

          state_fetcher = fn ["issue-refinement-transition"] ->
            fetch_count = Process.get(:refinement_fetch_count, 0) + 1
            Process.put(:refinement_fetch_count, fetch_count)

            state = if fetch_count == 1, do: "Refining", else: "Needs Refinement Review"
            {:ok, [%{issue | state: state}]}
          end

          assert :success =
                   AgentRunner.run(issue, nil,
                     workspace_creator: fn ^issue, nil, _opts -> {:ok, workspace} end,
                     refinement_start_transitioner: transitioner,
                     issue_state_fetcher: state_fetcher
                   )

          assert_receive :refinement_started
          trace = File.read!(trace_file)
          assert trace =~ "Current status: Refining"
        after
          File.rm_rf(test_root)
        end
      end

      test "agent runner stops before the first turn when refinement kickoff is rejected" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-refinement-rejected-#{System.unique_integer([:positive])}"
          )

        try do
          workspace = Path.join(test_root, "workspace")
          codex_binary = Path.join(test_root, "fake-codex")
          trace_file = Path.join(test_root, "codex.trace")

          File.mkdir_p!(workspace)

          File.write!(codex_binary, """
          #!/bin/sh
          trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/symphony-refinement-rejected.trace}"
          count=0
          while IFS= read -r line; do
            count=$((count + 1))
            printf 'LINE%s:%s\\n' "$count" "$line" >> "$trace_file"
            case "$count" in
              1) printf '%s\\n' '{"id":1,"result":{}}' ;;
              3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-refinement-rejected"}}}' ;;
            esac
          done
          """)

          File.chmod!(codex_binary, 0o755)
          previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")
          on_exit(fn -> restore_env("SYMP_TEST_CODEX_TRACE", previous_trace) end)
          System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: test_root,
            codex_command: "#{codex_binary} app-server",
            prompt: "Current status: {{ issue.state }}"
          )

          issue = %Issue{
            id: "issue-refinement-rejected",
            identifier: "MT-REFINE-REJECTED",
            title: "Reject refinement kickoff",
            description: "Do not start the turn",
            state: "Todo",
            labels: []
          }

          assert {:failed, {:refinement_start_transition_failed, :linear_rejected}} =
                   AgentRunner.run(issue, nil,
                     workspace_creator: fn ^issue, nil, _opts -> {:ok, workspace} end,
                     refinement_start_transitioner: fn ^issue, "Refining" -> {:error, :linear_rejected} end
                   )

          trace = File.read!(trace_file)
          assert trace =~ "thread/start"
        after
          File.rm_rf(test_root)
        end
      end

      test "agent runner stops before first turn when ready to in progress transition fails" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-agent-runner-ready-transition-failure-#{System.unique_integer([:positive])}"
          )

        try do
          workspace_root = Path.join(test_root, "workspaces")
          codex_binary = Path.join(test_root, "fake-codex")
          trace_file = Path.join(test_root, "codex.trace")

          File.mkdir_p!(test_root)

          File.write!(codex_binary, """
          #!/bin/sh
          trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/symphony-ready-transition-failure.trace}"
          count=0
          while IFS= read -r line; do
            count=$((count + 1))
            printf 'LINE%s:%s\\n' "$count" "$line" >> "$trace_file"
            case "$count" in
              1)
                printf '%s\\n' '{\"id\":1,\"result\":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-ready-fail\"}}}'
                ;;
              *)
                ;;
            esac
          done
          """)

          File.chmod!(codex_binary, 0o755)

          previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

          on_exit(fn ->
            restore_env("SYMP_TEST_CODEX_TRACE", previous_trace)
          end)

          System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            hook_after_create: "printf ready > README.md",
            codex_command: "#{codex_binary} app-server",
            prompt: "Current status: {{ issue.state }}"
          )

          issue = %Issue{
            id: "issue-ready-transition-failure",
            identifier: "MT-READY-TRANSITION-FAIL",
            title: "Transition failure",
            description: "Do not send first turn",
            state: "Ready",
            url: "https://example.org/issues/MT-READY-TRANSITION-FAIL",
            labels: []
          }

          transitioner = fn _transition_issue, "In Progress" -> {:error, :linear_state_not_found} end

          assert {:failed, {:implementation_start_transition_failed, :linear_state_not_found}} =
                   AgentRunner.run(issue, nil, implementation_start_transitioner: transitioner)

          trace = File.read!(trace_file)
          assert trace =~ "thread/start"
        after
          File.rm_rf(test_root)
        end
      end
    end
  end
end

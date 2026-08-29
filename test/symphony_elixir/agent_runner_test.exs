defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

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
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
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
      assert :ok = AgentRunner.run(issue)
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
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
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

      assert :ok =
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
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
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

      assert :ok =
               AgentRunner.run(issue, nil,
                 implementation_start_transitioner: transitioner,
                 issue_state_fetcher: fn ["issue-ready-transition"] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:implementation_started, "In Progress"}

      trace = File.read!(trace_file)
      assert trace =~ "Current status: In Progress"
      refute trace =~ "Current status: Ready"
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
        flunk("Ready issue should not transition when Codex startup fails")
      end

      assert {:error, {:codex_startup_failed, _details}} =
               AgentRunner.run(issue, nil, implementation_start_transitioner: transitioner)
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

      assert {:error, {:implementation_start_transition_failed, :linear_state_not_found}} =
               AgentRunner.run(issue, nil, implementation_start_transitioner: transitioner)

      trace = File.read!(trace_file)
      assert trace =~ "thread/start"
      refute trace =~ "Current status:"
    after
      File.rm_rf(test_root)
    end
  end

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

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert {:error, {:workspace_prepare_failed, "worker-a", 75, "worker-a prepare failed\n"}} =
               AgentRunner.run(issue, nil, worker_host: "worker-a")

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
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

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
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
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
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
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
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

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, nil,
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

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-handoff"}}}'
            ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-handoff"}}}'
            printf '%s\n' '{"id":104,"method":"item/tool/call","params":{"tool":"linear_task_update","callId":"call-handoff","threadId":"thread-handoff","turnId":"turn-handoff","arguments":{"target_state":"Ready to Merge","comment":"Completed: handoff; Validation: green; Deviations: None; Blockers: None","result":{"completed":"handoff","validation":"green","deviations":"None","blockers":"None"},"references":{"branch":"feature/sym-1"}}}}'
            ;;
          5)
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        project_repository_url: "https://github.com/acme/app",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
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
                       "nodes" => [
                         %{"id" => "state-ready-to-merge", "name" => "Ready to Merge"}
                       ]
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

      assert :ok =
               AgentRunner.run(issue, nil,
                 workspace_creator: fn ^issue, nil, _opts -> {:ok, workspace} end,
                 implementation_branch_checkout: fn ^workspace, "feature/sym-1", _opts ->
                   {:ok, "checked out"}
                 end,
                 pull_request_ensurer: pull_request_ensurer,
                 dynamic_tool_opts: [graphql: graphql],
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
        FakePersistence.list_events(issue_identifier: "SYM-1", event_type: "run.phase")
        |> Enum.filter(&(&1.payload.phase == "implementation_handoff"))

      assert Enum.map(events, & &1.payload.status) == ["completed", "started"]
      assert Enum.all?(events, &(&1.run_id == "run-handoff"))
      assert Enum.all?(events, &(&1.payload.session_id == "thread-handoff-turn-handoff"))
      assert List.first(events).payload.url == "https://github.com/acme/app/pull/12"
    after
      File.rm_rf(test_root)
    end
  end
end

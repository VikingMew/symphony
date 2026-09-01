defmodule SymphonyElixir.Codex.AppServerStartupPolicyTest do
  use SymphonyElixir.TestSupport

  test "app server startup failure includes command workspace status and output" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-app-server-startup-context-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-STARTUP")
      File.mkdir_p!(workspace)

      command = "printf 'codex: command not found\\n' >&2; sleep 0.05; exit 127"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: command
      )

      assert {:error, {:codex_startup_failed, details}} = AppServer.start_session(workspace)
      assert details.reason == :port_exit
      assert details.exit_status == 127
      assert details.command =~ "exit 127"
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert details.workspace == canonical_workspace
      assert details.worker_host == "local"
      assert details.output =~ "codex: command not found"
      assert details.hint =~ "Command not found"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup timeout includes bounded output" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-app-server-startup-timeout-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TIMEOUT")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "printf 'booting nvs\\n'; sleep 1",
        codex_read_timeout_ms: 500
      )

      assert {:error, {:codex_startup_failed, details}} = AppServer.start_session(workspace)
      assert details.reason == :response_timeout
      assert details.timeout_ms == 500
      assert details.output =~ "booting nvs"
      assert details.hint =~ "read_timeout_ms"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server runs pre-start commands in the same shell before codex command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-pre-start-path-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PRESTART")
      fake_bin = Path.join(test_root, "bin")
      codex_binary = Path.join(fake_bin, "fake-codex")
      trace_file = Path.join(test_root, "codex-pre-start.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)
      File.mkdir_p!(fake_bin)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-pre-start.trace}"
      printf 'PATH:%s\\n' "$PATH" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-prestart"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-prestart"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "fake-codex app-server",
        codex_pre_start_commands: ["export PATH=#{fake_bin}:$PATH"]
      )

      issue = %Issue{
        id: "issue-prestart",
        identifier: "MT-PRESTART",
        title: "Use pre-start PATH",
        description: "Ensure pre-start commands prepare Codex shell",
        state: "In Progress",
        url: "https://example.org/issues/MT-PRESTART",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Run with prepared PATH", issue)
      assert File.read!(trace_file) =~ "PATH:#{fake_bin}:"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server pre-start command failure stops before launching codex" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-pre-start-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PRESTART-FAIL")
      marker_file = Path.join(test_root, "codex-started")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "printf started > #{marker_file}; sleep 1",
        codex_pre_start_commands: ["printf preparing", "false"]
      )

      assert {:error, {:codex_startup_failed, details}} = AppServer.start_session(workspace)
      assert details.reason == :port_exit
      assert details.output =~ "Symphony Codex pre-start command 2 failed"
      assert details.hint =~ "Settings / Workflow / Codex / Pre-start commands"
      refute File.exists?(marker_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup approval policy response error points to workflow settings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-policy-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-APPROVAL")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r _line; do
        printf '%s\\n' '{"id":1,"error":{"code":-32600,"message":"Invalid request: unknown variant `reject`, expected one of `untrusted`, `on-failure`, `on-request`, `granular`, `never`"}}'
        exit 0
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_read_timeout_ms: 500
      )

      assert {:error, {:codex_startup_failed, details}} = AppServer.start_session(workspace)
      assert details.reason == :response_error
      assert details.stage == :initialize
      assert details.response_error["message"] =~ "unknown variant `reject`"
      assert details.hint =~ "Settings / Workflow / Codex / Approval policy"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes runtime proxy and credential environment to codex child process" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-proxy-env-#{System.unique_integer([:positive])}"
      )

    proxy_env_names = SymphonyElixir.RuntimeProxy.proxy_env_names()
    previous_proxy_env = Map.new(proxy_env_names, &{&1, System.get_env(&1)})
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      Enum.each(previous_proxy_env, fn {name, value} -> restore_env(name, value) end)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    Enum.each(proxy_env_names, &System.delete_env/1)
    System.put_env("HTTPS_PROXY", "http://user:pass@proxy.example.test:8080")
    System.put_env("NO_PROXY", "127.0.0.1,localhost")
    System.put_env("LINEAR_API_KEY", "must-not-reach-codex")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PROXY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-proxy-env.trace")

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-proxy-env.trace}"
      printf 'HTTPS_PROXY=%s\\n' "${HTTPS_PROXY:-}" >> "$trace_file"
      printf 'NO_PROXY=%s\\n' "${NO_PROXY:-}" >> "$trace_file"
      printf 'LINEAR_API_KEY=%s\\n' "${LINEAR_API_KEY:-}" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-proxy"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-proxy"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-proxy-env",
        identifier: "MT-PROXY",
        title: "Validate runtime proxy env",
        description: "Ensure Codex receives proxy environment variables",
        state: "In Progress",
        url: "https://example.org/issues/MT-PROXY",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate proxy env", issue)

      trace = File.read!(trace_file)
      assert trace =~ "HTTPS_PROXY=http://user:pass@proxy.example.test:8080"
      assert trace =~ "NO_PROXY=127.0.0.1,localhost"
      assert trace =~ "LINEAR_API_KEY=must-not-reach-codex"
    after
      File.rm_rf(test_root)
    end
  end
end

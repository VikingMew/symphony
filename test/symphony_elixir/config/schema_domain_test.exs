defmodule SymphonyElixir.Config.SchemaDomainTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.StringOrMap

  test "projects schema defaults to external config" do
    defaults = Schema.defaults()

    assert get_in(defaults, ["workspace", "root"]) ==
             Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert get_in(defaults, ["agent", "max_concurrent_agents"]) == 10
    refute Map.has_key?(defaults["tracker"], "api_key")
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.workspace.initialize_timeout_ms == 60_000
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"
    assert config.codex.pre_start_commands == []
    assert config.codex.approval_policy == "never"
    assert config.codex.thread_sandbox == "workspace-write"

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server",
      codex_pre_start_commands: ["source ~/.nvs/nvs.sh", "nvs use 22 >/dev/null"]
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    assert Config.settings!().codex.pre_start_commands == [
             "source ~/.nvs/nvs.sh",
             "nvs use 22 >/dev/null"
           ]

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert config.codex.turn_sandbox_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), initialize_timeout_ms: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workspace.initialize_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "",
      project_repository_url: "git@example.com:org/repo.git"
    )

    System.put_env("LINEAR_API_KEY", "token")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == "never"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_thread_sandbox: "",
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      project_checkout_depth: 0
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "project.checkout_depth"

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      project_setup_commands: [""]
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "project.setup_commands commands must not be blank"

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      codex_approval_policy: "future-policy"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      codex_thread_sandbox: "future-sandbox",
      turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.thread_sandbox == "future-sandbox"

    assert config.codex.turn_sandbox_policy == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves LINEAR_API_KEY and $VAR path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.put_env(workspace_env_var, workspace_root)
    System.put_env("LINEAR_API_KEY", api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "stale-workflow-token",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)
    System.put_env("LINEAR_API_KEY", "runtime-linear-token")

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "runtime-linear-token"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 10,
      max_concurrent_agents_by_state: %{
        todo: 1,
        "In Progress": 4,
        "In Review": 2
      }
    )

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(),
      worker_max_concurrent_agents_per_host: 2,
      project_repository_url: "git@example.com:org/repo.git"
    )

    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse reads token only from LINEAR_API_KEY" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    System.delete_env("LINEAR_API_KEY")

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "stale-workflow-token"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema parse rejects legacy codex approval policy maps" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert message =~ "codex.approval_policy"
    assert message =~ "is invalid"
  end

  test "schema parse normalizes only blank approval policy maps to never" do
    assert {:ok, settings} =
             Schema.parse(%{
               codex: %{approval_policy: %{}}
             })

    assert settings.codex.approval_policy == "never"
  end

  test "schema rejects Linear state names longer than Linear allows" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               tracker: %{
                 active_states: ["Ready", "Needs Implementation Review"],
                 terminal_states: ["Done"]
               },
               workflow: %{
                 states: %{"Ready" => %{profile: "implementation"}},
                 human_review_states: ["Needs Implementation Review"],
                 allowed_transitions: [
                   %{from: "Ready", to: "Needs Implementation Review", actor: "codex", profile: "implementation"}
                 ]
               },
               profiles: %{
                 implementation: %{
                   name: "Implementation",
                   executor: %{type: "codex_agent"},
                   prompt: %{mode: "extend", template: "Implement"},
                   allowed_updates: %{target_states: ["Needs Implementation Review"]}
                 }
               }
             })

    assert message =~ "Linear state name limit of 25 characters"
    assert message =~ "Needs Implementation Review"
    assert message =~ "tracker.active_states"
    assert message =~ "human_review_states"
    assert message =~ "allowed_transitions.to"
    assert message =~ "profiles.implementation.allowed_updates.target_states"
  end

  test "schema keeps workspace roots raw while runtime resolution preserves remote roots" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end
end

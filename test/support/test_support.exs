defmodule SymphonyElixir.TestSupport.WorkflowFixtures do
  @moduledoc false

  alias SymphonyElixir.Config.Schema

  def workflow_package_yaml(config) when is_map(config), do: yaml_document(config)

  def profiles_package_yaml(profiles, prompt) do
    "base_prompt: |\n" <> indent_block(prompt) <> "\nprofiles: #{yaml_value(profiles)}\n"
  end

  def settings_workflow_yaml do
    workflow_package_yaml(%{
      "tracker" => %{
        "kind" => "linear",
        "endpoint" => "https://api.linear.app/graphql",
        "project_slug" => "project",
        "active_states" => ["Todo", "Ready", "In Progress"],
        "terminal_states" => ["Canceled", "Cancelled", "Duplicate", "Done"]
      },
      "polling" => %{"interval_ms" => 30_000},
      "project" => %{
        "repository_url" => "git@github.com:org/imported.git",
        "default_branch" => "main",
        "checkout_depth" => 1,
        "setup_commands" => [],
        "cleanup_commands" => []
      },
      "workspace" => %{"root" => "/tmp/imported-workspaces"},
      "agent" => %{"max_concurrent_agents" => 1, "max_turns" => 20},
      "codex" => %{
        "command" => "codex app-server",
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write"
      },
      "server" => %{"host" => "127.0.0.1", "port" => 4000},
      "workflow" => Schema.default_workflow_policy()
    })
  end

  def settings_profiles_yaml do
    profiles_package_yaml(
      %{
        "refinement" => %{
          "name" => "Refinement",
          "executor" => %{"type" => "codex_agent"},
          "prompt" => %{"mode" => "extend", "template" => "Imported refinement prompt."},
          "allowed_updates" => %{
            "description" => true,
            "comment" => true,
            "result" => false,
            "target_states" => ["Needs Refinement Review"]
          }
        },
        "implementation" => %{
          "name" => "Implementation",
          "executor" => %{"type" => "codex_agent"},
          "prompt" => %{"mode" => "extend", "template" => "Imported implementation prompt."},
          "allowed_updates" => %{
            "description" => false,
            "comment" => true,
            "result" => true,
            "target_states" => ["In Progress", "Ready to Merge"]
          }
        }
      },
      "Imported base prompt."
    )
  end

  def yaml_document(config) do
    config
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{yaml_value(value)}" end)
    |> Kernel.<>("\n")
  end

  def yaml_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  def yaml_value(value) when is_integer(value), do: to_string(value)
  def yaml_value(value) when is_float(value), do: Float.to_string(value)
  def yaml_value(true), do: "true"
  def yaml_value(false), do: "false"
  def yaml_value(nil), do: "null"

  def yaml_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &yaml_value/1) <> "]"
  end

  def yaml_value(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, nested} -> "#{key}: #{yaml_value(nested)}" end)
    |> then(&"{#{&1}}")
  end

  defp indent_block(prompt) do
    prompt
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &("  " <> &1))
  end
end

defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.TestSupport.WorkflowFixtures
  alias SymphonyElixir.{Workflow, WorkflowStore}

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
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
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        FakePersistence.reset!()
        Health.reset!()
        previous_linear_api_key = System.get_env("LINEAR_API_KEY")
        System.put_env("LINEAR_API_KEY", "token")

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "workflow.yml")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          restore_env("LINEAR_API_KEY", previous_linear_api_key)
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    {:ok, loaded} = Workflow.parse_content(workflow)
    {profiles, workflow_config} = Map.pop(loaded.config, "profiles", %{})
    workflow_path = split_workflow_path(path)
    profiles_path = Path.join(Path.dirname(workflow_path), "profiles.yml")

    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, WorkflowFixtures.workflow_package_yaml(workflow_config))
    File.write!(profiles_path, WorkflowFixtures.profiles_package_yaml(profiles, loaded.prompt))
    seed_fake_current_workflow(workflow_path)

    if Process.whereis(WorkflowStore) do
      try do
        WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp seed_fake_current_workflow(workflow_path) do
    if Application.get_env(:symphony_elixir, :persistence_module) == FakePersistence do
      {:ok, loaded} = Workflow.load(workflow_path)
      FakePersistence.put_default_project_attrs!(project_attrs_from_workflow_config(loaded.config))
      raw = Workflow.to_markdown(loaded.config, loaded.prompt)
      {:ok, project} = FakePersistence.default_project()
      {:ok, _version} = FakePersistence.import_workflow(project, raw, "test")
    end
  end

  defp project_attrs_from_workflow_config(config) when is_map(config) do
    project = Map.get(config, "project", %{})
    tracker = Map.get(config, "tracker", %{})

    %{
      linear_project_slug: Map.get(tracker, "project_slug"),
      repository_url: Map.get(project, "repository_url"),
      default_branch: Map.get(project, "default_branch", "main"),
      checkout_depth: Map.get(project, "checkout_depth", 1),
      source_strategy: Map.get(project, "source_strategy", "clone"),
      worktree_fetch: Map.get(project, "worktree_fetch", true),
      worktree_cleanup: Map.get(project, "worktree_cleanup", true)
    }
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  defp split_workflow_path(path) do
    if Path.basename(path) in ["workflow.yml", "workflow.yaml"],
      do: path,
      else: Path.join(Path.dirname(path), "workflow.yml")
  end

  def stop_default_http_server do
    children =
      case Process.whereis(SymphonyElixir.Supervisor) do
        nil -> []
        _pid -> Supervisor.which_children(SymphonyElixir.Supervisor)
      end

    case Enum.find(children, fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: nil,
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "Ready", "In Progress"],
          tracker_terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          initialize_timeout_ms: 60_000,
          project_repository_url: nil,
          project_default_branch: "main",
          project_checkout_depth: 1,
          project_setup_commands: [],
          project_cleanup_commands: [],
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_pre_start_commands: [],
          codex_approval_policy: "never",
          codex_thread_sandbox: "workspace-write",
          turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          codex_rate_limit_gate_enabled: true,
          codex_rate_limit_gate_5h_threshold_percent: 5.0,
          codex_rate_limit_gate_7d_threshold_percent: 3.0,
          codex_rate_limit_gate_post_reset_delay_ms: 1_200_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          workflow_policy: nil,
          profiles_policy: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    workspace_repository_base_root = Keyword.get(config, :workspace_repository_base_root)
    workspace_worktree_base_root = Keyword.get(config, :workspace_worktree_base_root)
    initialize_timeout_ms = Keyword.get(config, :initialize_timeout_ms)
    project_config = project_config(config)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_pre_start_commands = Keyword.get(config, :codex_pre_start_commands)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    turn_sandbox_policy = Keyword.get(config, :turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    codex_rate_limit_gate_enabled = Keyword.get(config, :codex_rate_limit_gate_enabled)
    codex_rate_limit_gate_5h_threshold_percent = Keyword.get(config, :codex_rate_limit_gate_5h_threshold_percent)
    codex_rate_limit_gate_7d_threshold_percent = Keyword.get(config, :codex_rate_limit_gate_7d_threshold_percent)
    codex_rate_limit_gate_post_reset_delay_ms = Keyword.get(config, :codex_rate_limit_gate_post_reset_delay_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    workflow_policy = Keyword.get(config, :workflow_policy)
    profiles_policy = Keyword.get(config, :profiles_policy)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        tracker_api_key_yaml(tracker_api_token),
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "  repository_base_root: #{yaml_value(workspace_repository_base_root)}",
        "  worktree_base_root: #{yaml_value(workspace_worktree_base_root)}",
        "  initialize_timeout_ms: #{yaml_value(initialize_timeout_ms)}",
        project_yaml(project_config),
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  pre_start_commands: #{yaml_value(codex_pre_start_commands)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "  rate_limit_gate_enabled: #{yaml_value(codex_rate_limit_gate_enabled)}",
        "  rate_limit_gate_5h_threshold_percent: #{yaml_value(codex_rate_limit_gate_5h_threshold_percent)}",
        "  rate_limit_gate_7d_threshold_percent: #{yaml_value(codex_rate_limit_gate_7d_threshold_percent)}",
        "  rate_limit_gate_post_reset_delay_ms: #{yaml_value(codex_rate_limit_gate_post_reset_delay_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        workflow_yaml(workflow_policy),
        profiles_yaml(profiles_policy),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp tracker_api_key_yaml(nil), do: nil
  defp tracker_api_key_yaml(token), do: "  api_key: #{yaml_value(token)}"

  defp workflow_yaml(nil), do: nil
  defp workflow_yaml(policy), do: "workflow: #{yaml_value(policy)}"
  defp profiles_yaml(nil), do: nil
  defp profiles_yaml(policy), do: "profiles: #{yaml_value(policy)}"

  defp project_config(config) do
    %{
      repository_url: Keyword.get(config, :project_repository_url),
      default_branch: Keyword.get(config, :project_default_branch),
      checkout_depth: Keyword.get(config, :project_checkout_depth),
      source_strategy: Keyword.get(config, :project_source_strategy),
      worktree_fetch: Keyword.get(config, :project_worktree_fetch),
      worktree_cleanup: Keyword.get(config, :project_worktree_cleanup),
      setup_commands: Keyword.get(config, :project_setup_commands),
      cleanup_commands: Keyword.get(config, :project_cleanup_commands)
    }
  end

  defp project_yaml(%{
         repository_url: nil,
         default_branch: _default_branch,
         checkout_depth: _checkout_depth,
         source_strategy: nil,
         worktree_fetch: nil,
         worktree_cleanup: nil,
         setup_commands: [],
         cleanup_commands: []
       }),
       do: nil

  defp project_yaml(project) do
    [
      "project:",
      "  repository_url: #{yaml_value(project.repository_url)}",
      "  default_branch: #{yaml_value(project.default_branch)}",
      "  checkout_depth: #{yaml_value(project.checkout_depth)}",
      "  source_strategy: #{yaml_value(project.source_strategy)}",
      "  worktree_fetch: #{yaml_value(project.worktree_fetch)}",
      "  worktree_cleanup: #{yaml_value(project.worktree_cleanup)}",
      "  setup_commands: #{yaml_value(project.setup_commands)}",
      "  cleanup_commands: #{yaml_value(project.cleanup_commands)}"
    ]
    |> Enum.join("\n")
  end

  defp yaml_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end

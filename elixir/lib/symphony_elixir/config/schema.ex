defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"])
      field(:terminal_states, {:array, :string}, default: ["Canceled", "Cancelled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Project do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:repository_url, :string)
      field(:default_branch, :string, default: "main")
      field(:checkout_depth, :integer, default: 1)
      field(:setup_commands, {:array, :string}, default: [])
      field(:cleanup_commands, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:repository_url, :default_branch, :checkout_depth, :setup_commands, :cleanup_commands],
        empty_values: []
      )
      |> validate_optional_non_blank(:repository_url)
      |> validate_optional_non_blank(:default_branch)
      |> validate_number(:checkout_depth, greater_than: 0)
      |> validate_command_list(:setup_commands)
      |> validate_command_list(:cleanup_commands)
    end

    defp validate_optional_non_blank(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and String.trim(value) == "", do: [{field, "must not be blank"}], else: []
      end)
    end

    defp validate_command_list(changeset, field) do
      validate_change(changeset, field, fn ^field, commands ->
        Enum.flat_map(commands || [], &command_error(field, &1))
      end)
    end

    defp command_error(field, command) when is_binary(command) do
      if String.trim(command) == "", do: [{field, "commands must not be blank"}], else: []
    end

    defp command_error(field, _command), do: [{field, "commands must be strings"}]
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:project, Project, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    field(:workflow, :map, default: %{})
    field(:profiles, :map, default: %{})
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec workflow_profile_for_state(%__MODULE__{}, String.t() | nil) :: String.t() | nil
  def workflow_profile_for_state(%__MODULE__{workflow: workflow}, state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(String.trim(state_name))

    workflow
    |> Map.get("states", %{})
    |> Enum.find_value(fn {configured_state, state_policy} ->
      if normalize_issue_state(configured_state) == normalized_state do
        Map.get(state_policy, "profile")
      end
    end)
  end

  def workflow_profile_for_state(_settings, _state_name), do: nil

  @doc false
  @spec workflow_profile(%__MODULE__{}, String.t() | nil) :: map()
  def workflow_profile(%__MODULE__{profiles: profiles}, profile) when is_binary(profile) do
    case Map.get(profiles, profile) do
      %{} = policy -> policy
      _ -> %{}
    end
  end

  def workflow_profile(_settings, _profile), do: %{}

  @doc false
  @spec workflow_executor_for_state(%__MODULE__{}, String.t() | nil) :: String.t() | nil
  def workflow_executor_for_state(settings, state_name) do
    profile = workflow_profile_for_state(settings, state_name)

    settings
    |> workflow_profile(profile)
    |> get_in(["executor", "type"])
  end

  @doc false
  @spec human_review_state?(%__MODULE__{}, String.t() | nil) :: boolean()
  def human_review_state?(%__MODULE__{workflow: workflow}, state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(String.trim(state_name))

    workflow
    |> Map.get("human_review_states", [])
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.member?(normalized_state)
  end

  def human_review_state?(_settings, _state_name), do: false

  @doc false
  @spec workflow_allowed_updates(%__MODULE__{}, String.t() | nil) :: map()
  def workflow_allowed_updates(%__MODULE__{profiles: profiles}, profile) when is_binary(profile) do
    profiles
    |> get_in([profile, "allowed_updates"])
    |> case do
      updates when is_map(updates) -> updates
      _ -> %{}
    end
  end

  def workflow_allowed_updates(_settings, _profile), do: %{}

  @doc false
  @spec generated_after_create_hook(%__MODULE__{}) :: String.t() | nil
  def generated_after_create_hook(%__MODULE__{project: %Project{} = project}) do
    commands =
      []
      |> maybe_append_clone_command(project)
      |> Kernel.++(project.setup_commands || [])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if commands == [], do: nil, else: Enum.join(commands, "\n")
  end

  def generated_after_create_hook(_settings), do: nil

  @doc false
  @spec generated_before_remove_hook(%__MODULE__{}) :: String.t() | nil
  def generated_before_remove_hook(%__MODULE__{project: %Project{} = project}) do
    commands =
      project.cleanup_commands
      |> List.wrap()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if commands == [], do: nil, else: Enum.join(commands, "\n")
  end

  def generated_before_remove_hook(_settings), do: nil

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp maybe_append_clone_command(commands, %Project{repository_url: repository_url})
       when not is_binary(repository_url) or repository_url == "" do
    commands
  end

  defp maybe_append_clone_command(commands, %Project{} = project) do
    clone_parts =
      ["GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=", "SSH_ASKPASS="]
      |> maybe_append_git_ssh_command(project.repository_url)
      |> Kernel.++([
        "git",
        "-c",
        "credential.helper=",
        "-c",
        "core.askPass=",
        "-c",
        "http.lowSpeedLimit=1",
        "-c",
        "http.lowSpeedTime=30",
        "clone",
        "--progress"
      ])
      |> maybe_append_clone_depth(project.checkout_depth)
      |> maybe_append_clone_branch(project.default_branch)
      |> Kernel.++([shell_escape(project.repository_url), "."])

    commands ++ [Enum.join(clone_parts, " ")]
  end

  defp maybe_append_git_ssh_command(parts, repository_url) when is_binary(repository_url) do
    if ssh_repository_url?(repository_url) do
      parts ++
        [
          "GIT_SSH_COMMAND=#{shell_escape("ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new")}"
        ]
    else
      parts
    end
  end

  defp maybe_append_git_ssh_command(parts, _repository_url), do: parts

  defp ssh_repository_url?(repository_url) do
    String.starts_with?(repository_url, "git@") or String.starts_with?(repository_url, "ssh://")
  end

  defp maybe_append_clone_depth(parts, depth) when is_integer(depth) and depth > 0 do
    parts ++ ["--depth", Integer.to_string(depth)]
  end

  defp maybe_append_clone_depth(parts, _depth), do: parts

  defp maybe_append_clone_branch(parts, branch) when is_binary(branch) and branch != "" do
    parts ++ ["--branch", shell_escape(branch)]
  end

  defp maybe_append_clone_branch(parts, _branch), do: parts

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:workflow, :profiles])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:project, with: &Project.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> validate_workflow_contract()
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    workflow = normalize_workflow_policy(settings.workflow)
    profiles = normalize_profiles(settings.profiles)

    %{settings | tracker: tracker, workspace: workspace, codex: codex, workflow: workflow, profiles: profiles}
  end

  @doc false
  @spec default_workflow_policy() :: map()
  def default_workflow_policy do
    %{
      "states" => %{
        "Refining" => %{"profile" => "refinement"},
        "Ready" => %{"profile" => "implementation"},
        "In Progress" => %{"profile" => "implementation"},
        "Ready to Merge" => %{"profile" => "merge"},
        "Merging" => %{"profile" => "merge"}
      },
      "human_review_states" => ["Needs Refinement Review", "Needs Implementation Review"],
      "allowed_transitions" => [
        %{"from" => "Refining", "to" => "Needs Refinement Review", "actor" => "codex", "profile" => "refinement"},
        %{"from" => "Needs Refinement Review", "to" => "Ready", "actor" => "human"},
        %{"from" => "Needs Refinement Review", "to" => "Refining", "actor" => "human"},
        %{"from" => "Ready", "to" => "In Progress", "actor" => "codex", "profile" => "implementation"},
        %{"from" => "In Progress", "to" => "Needs Implementation Review", "actor" => "codex", "profile" => "implementation"},
        %{"from" => "Needs Implementation Review", "to" => "Ready to Merge", "actor" => "human"},
        %{"from" => "Needs Implementation Review", "to" => "In Progress", "actor" => "human"},
        %{"from" => "Ready to Merge", "to" => "Merging", "actor" => "codex", "profile" => "merge"},
        %{"from" => "Merging", "to" => "Done", "actor" => "codex", "profile" => "merge"},
        %{"from" => "Ready to Merge", "to" => "In Progress", "actor" => "human"}
      ],
      "tool_policy" => %{
        "linear" => %{
          "exposed_tools" => ["linear_task_read", "linear_task_update"],
          "raw_graphql" => false
        }
      }
    }
  end

  @doc false
  @spec default_profiles() :: map()
  def default_profiles do
    %{
      "refinement" => %{
        "name" => "Refinement",
        "executor" => %{"type" => "codex_agent"},
        "prompt" => %{
          "mode" => "extend",
          "template" =>
            "Workflow profile: {{ workflow.profile_name }}\n\nRead the task and recent Linear comments. Refine the task description and acceptance criteria only when the feedback and repository context justify it. When the task is ready for human confirmation, add a concise comment and request one of the allowed target states."
        },
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
        "prompt" => %{
          "mode" => "extend",
          "template" =>
            "Workflow profile: {{ workflow.profile_name }}\n\nRead the task and recent Linear comments before changing code. Implement, test, and verify the requested work in the workspace. When ready for review, add the result, relevant references, a concise comment, and request one of the allowed target states."
        },
        "allowed_updates" => %{
          "description" => false,
          "comment" => true,
          "result" => true,
          "target_states" => ["In Progress", "Needs Implementation Review"]
        }
      },
      "merge" => %{
        "name" => "Merge",
        "executor" => %{"type" => "codex_agent"},
        "prompt" => %{
          "mode" => "extend",
          "template" =>
            "Workflow profile: {{ workflow.profile_name }}\n\nRead the task and recent Linear comments before merging. Verify the branch is ready, perform the merge workflow when allowed, and add a concise result comment with an allowed target state."
        },
        "allowed_updates" => %{
          "description" => false,
          "comment" => true,
          "result" => true,
          "target_states" => ["Merging", "Done"]
        }
      }
    }
  end

  defp normalize_workflow_policy(policy) when is_map(policy) do
    default = default_workflow_policy()
    policy = normalize_keys(policy)

    Map.merge(default, policy)
  end

  defp normalize_workflow_policy(_policy), do: default_workflow_policy()

  defp normalize_profiles(profiles) when is_map(profiles) do
    configured_profiles = normalize_keys(profiles)

    default_profiles()
    |> Map.merge(configured_profiles, fn _profile, default_profile, configured_profile ->
      Map.merge(default_profile, configured_profile)
    end)
  end

  defp normalize_profiles(_profiles), do: default_profiles()

  defp validate_workflow_contract(changeset) do
    workflow = get_field(changeset, :workflow) || %{}
    profiles = get_field(changeset, :profiles) || %{}
    tracker = get_field(changeset, :tracker)

    workflow_errors =
      workflow
      |> normalize_keys()
      |> workflow_policy_errors(normalize_keys(profiles), tracker)

    profile_errors =
      profiles
      |> normalize_keys()
      |> profile_policy_errors()

    Enum.reduce(workflow_errors, changeset, &add_error(&2, :workflow, &1))
    |> then(fn changeset -> Enum.reduce(profile_errors, changeset, &add_error(&2, :profiles, &1)) end)
  end

  defp workflow_policy_errors(workflow, profiles, tracker) when is_map(workflow) do
    []
    |> Kernel.++(validate_no_nested_profiles(workflow))
    |> Kernel.++(validate_states(Map.get(workflow, "states", %{}), profiles))
    |> Kernel.++(validate_string_list(Map.get(workflow, "human_review_states", []), "human_review_states"))
    |> Kernel.++(validate_transitions(Map.get(workflow, "allowed_transitions", [])))
    |> Kernel.++(validate_workflow_state_references(workflow, profiles, tracker))
  end

  defp workflow_policy_errors(_workflow, _profiles, _tracker), do: ["must be a map"]

  defp validate_no_nested_profiles(workflow) do
    if Map.has_key?(workflow, "profiles") do
      ["workflow.profiles is not supported; define profiles at top-level profiles"]
    else
      []
    end
  end

  defp validate_states(states, profiles) when is_map(states) do
    known_profiles =
      default_profiles()
      |> Map.merge(profiles)
      |> Map.keys()
      |> MapSet.new()

    Enum.flat_map(states, fn {state, policy} ->
      profile = if is_map(policy), do: Map.get(policy, "profile")

      cond do
        not is_binary(state) or String.trim(state) == "" ->
          ["states must use non-empty state names"]

        not is_map(policy) ->
          ["states.#{state} must be a map"]

        not is_binary(profile) or String.trim(profile) == "" ->
          ["states.#{state}.profile must be a non-empty string"]

        not MapSet.member?(known_profiles, profile) ->
          ["states.#{state}.profile references unknown profile #{profile}"]

        true ->
          []
      end
    end)
  end

  defp validate_states(_states, _profiles), do: ["states must be a map"]

  defp profile_policy_errors(profiles) when is_map(profiles) do
    Enum.flat_map(profiles, fn {profile, policy} ->
      cond do
        not is_binary(profile) or String.trim(profile) == "" ->
          ["profiles must use non-empty string names"]

        not is_map(policy) ->
          ["profiles.#{profile} must be a map"]

        Map.has_key?(policy, "active_states") ->
          ["profiles.#{profile}.active_states is not supported; use workflow.states"]

        true ->
          validate_profile_name(profile, Map.get(policy, "name")) ++
            validate_executor(profile, Map.get(policy, "executor")) ++
            validate_prompt_policy(profile, Map.get(policy, "prompt")) ++
            validate_profile_executor_prompt(profile, policy) ++
            validate_allowed_updates(profile, Map.get(policy, "allowed_updates", %{}))
      end
    end)
  end

  defp profile_policy_errors(_profiles), do: ["profiles must be a map"]

  defp validate_profile_name(profile, name) do
    if is_binary(name) and String.trim(name) != "" do
      []
    else
      ["profiles.#{profile}.name must be a non-empty string"]
    end
  end

  defp validate_executor(_profile, %{"type" => type}) when type in ["codex_agent", "manual", "backend_action", "external_worker"] do
    []
  end

  defp validate_executor(profile, %{"type" => _type}), do: ["profiles.#{profile}.executor.type is invalid"]
  defp validate_executor(profile, _executor), do: ["profiles.#{profile}.executor.type must be a non-empty string"]

  defp validate_prompt_policy(_profile, %{"mode" => mode}) when mode in ["extend", "replace", "disabled"], do: []
  defp validate_prompt_policy(profile, %{"mode" => _mode}), do: ["profiles.#{profile}.prompt.mode is invalid"]
  defp validate_prompt_policy(profile, _prompt), do: ["profiles.#{profile}.prompt.mode must be a non-empty string"]

  defp validate_profile_executor_prompt(profile, policy) do
    executor_type = get_in(policy, ["executor", "type"])
    prompt_mode = get_in(policy, ["prompt", "mode"])
    prompt_template = get_in(policy, ["prompt", "template"])

    cond do
      executor_type == "codex_agent" and prompt_mode == "disabled" ->
        ["profiles.#{profile}.prompt.mode cannot be disabled for codex_agent"]

      executor_type == "codex_agent" and prompt_mode in ["extend", "replace"] and not non_empty_string?(prompt_template) ->
        ["profiles.#{profile}.prompt.template must be a non-empty string for codex_agent #{prompt_mode} mode"]

      true ->
        []
    end
  end

  defp validate_allowed_updates(profile, updates) when is_map(updates) do
    validate_string_list(Map.get(updates, "target_states", []), "profiles.#{profile}.allowed_updates.target_states")
  end

  defp validate_allowed_updates(profile, _updates), do: ["profiles.#{profile}.allowed_updates must be a map"]

  defp validate_transitions(transitions) when is_list(transitions) do
    Enum.flat_map(transitions, fn
      transition when is_map(transition) ->
        from = Map.get(transition, "from")
        to = Map.get(transition, "to")
        actor = Map.get(transition, "actor")

        []
        |> maybe_required_string_error(from, "allowed_transitions.from")
        |> maybe_required_string_error(to, "allowed_transitions.to")
        |> maybe_actor_error(actor)

      _transition ->
        ["allowed_transitions entries must be maps"]
    end)
  end

  defp validate_transitions(_transitions), do: ["allowed_transitions must be a list"]

  defp validate_workflow_state_references(workflow, profiles, tracker) do
    used_profiles = workflow_used_profiles(workflow, profiles)

    profiles =
      default_profiles()
      |> Map.take(used_profiles)
      |> Map.merge(profiles, fn _profile, default_profile, configured_profile ->
        Map.merge(default_profile, configured_profile)
      end)

    known_states = workflow_known_states(workflow, tracker)

    validate_transition_state_references(Map.get(workflow, "allowed_transitions", []), known_states) ++
      validate_profile_target_state_references(profiles, known_states)
  end

  defp workflow_used_profiles(workflow, _profiles) do
    state_profiles =
      workflow
      |> Map.get("states", %{})
      |> Enum.map(fn {_state, policy} -> if is_map(policy), do: Map.get(policy, "profile") end)

    transition_profiles =
      workflow
      |> Map.get("allowed_transitions", [])
      |> Enum.map(fn transition -> if is_map(transition), do: Map.get(transition, "profile") end)

    state_profiles
    |> Kernel.++(transition_profiles)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp workflow_known_states(workflow, tracker) do
    []
    |> Kernel.++(tracker_states(tracker, :active_states))
    |> Kernel.++(tracker_states(tracker, :terminal_states))
    |> Kernel.++(Map.keys(Map.get(workflow, "states", %{})))
    |> Kernel.++(Map.get(workflow, "human_review_states", []))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new(&normalize_issue_state/1)
  end

  defp tracker_states(%Tracker{} = tracker, field), do: Map.get(tracker, field) || []
  defp tracker_states(_tracker, _field), do: []

  defp validate_transition_state_references(transitions, known_states) when is_list(transitions) do
    Enum.flat_map(transitions, fn
      transition when is_map(transition) ->
        Enum.flat_map(["from", "to"], &transition_state_reference_errors(transition, known_states, &1))

      _transition ->
        []
    end)
  end

  defp validate_transition_state_references(_transitions, _known_states), do: []

  defp transition_state_reference_errors(transition, known_states, field) do
    state = Map.get(transition, field)

    if known_state?(known_states, state) do
      []
    else
      ["allowed_transitions.#{field} references unknown workflow state #{inspect(state)}"]
    end
  end

  defp validate_profile_target_state_references(profiles, known_states) when is_map(profiles) do
    Enum.flat_map(profiles, fn {profile, policy} ->
      policy
      |> get_in(["allowed_updates", "target_states"])
      |> case do
        states when is_list(states) ->
          states
          |> Enum.reject(&known_state?(known_states, &1))
          |> Enum.map(&"profiles.#{profile}.allowed_updates.target_states references unknown workflow state #{inspect(&1)}")

        _states ->
          []
      end
    end)
  end

  defp validate_profile_target_state_references(_profiles, _known_states), do: []

  defp known_state?(known_states, state) when is_binary(state) do
    MapSet.member?(known_states, normalize_issue_state(String.trim(state)))
  end

  defp known_state?(_known_states, _state), do: true

  defp maybe_required_string_error(errors, value, field) do
    if is_binary(value) and String.trim(value) != "", do: errors, else: [field <> " must be a non-empty string" | errors]
  end

  defp maybe_actor_error(errors, actor) do
    if actor in ["codex", "human"], do: errors, else: ["allowed_transitions.actor must be either codex or human" | errors]
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_string_list(values, field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      []
    else
      [field <> " must be a list of non-empty strings"]
    end
  end

  defp validate_string_list(_values, field), do: [field <> " must be a list of non-empty strings"]

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end

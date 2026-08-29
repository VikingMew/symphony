defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.{ProjectCommands, RuntimeResolver, WorkflowContract}

  @primary_key false

  @type t :: %__MODULE__{}

  @codex_approval_policies ["untrusted", "on-failure", "on-request", "granular", "never"]

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
      field(:active_states, {:array, :string}, default: ["Refining", "Ready", "In Progress"])

      field(:terminal_states, {:array, :string}, default: ["Canceled", "Cancelled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :project_slug, :assignee, :active_states, :terminal_states],
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
      field(:repository_base_root, :string)
      field(:worktree_base_root, :string)
      field(:initialize_timeout_ms, :integer, default: 60_000)
      field(:min_free_bytes, :integer, default: 1_073_741_824)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :root,
          :repository_base_root,
          :worktree_base_root,
          :initialize_timeout_ms,
          :min_free_bytes
        ],
        empty_values: []
      )
      |> validate_optional_non_blank(:repository_base_root)
      |> validate_optional_non_blank(:worktree_base_root)
      |> validate_number(:initialize_timeout_ms, greater_than: 0)
      |> validate_number(:min_free_bytes, greater_than_or_equal_to: 0)
    end

    defp validate_optional_non_blank(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and String.trim(value) == "",
          do: [{field, "must not be blank"}],
          else: []
      end)
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
      field(:source_strategy, :string, default: "clone")
      field(:worktree_fetch, :boolean, default: true)
      field(:worktree_cleanup, :boolean, default: true)
      field(:setup_commands, {:array, :string}, default: [])
      field(:cleanup_commands, {:array, :string}, default: [])
      field(:required_gates, {:array, :map}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :repository_url,
          :default_branch,
          :checkout_depth,
          :source_strategy,
          :worktree_fetch,
          :worktree_cleanup,
          :setup_commands,
          :cleanup_commands,
          :required_gates
        ],
        empty_values: []
      )
      |> validate_optional_non_blank(:repository_url)
      |> validate_optional_non_blank(:default_branch)
      |> validate_number(:checkout_depth, greater_than: 0)
      |> validate_inclusion(:source_strategy, ["clone", "worktree"])
      |> validate_command_list(:setup_commands)
      |> validate_command_list(:cleanup_commands)
      |> validate_required_gates()
    end

    defp validate_optional_non_blank(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and String.trim(value) == "",
          do: [{field, "must not be blank"}],
          else: []
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

    defp validate_required_gates(changeset) do
      validate_change(changeset, :required_gates, &required_gate_errors/2)
    end

    defp required_gate_errors(:required_gates, gates) do
      gates
      |> Enum.with_index()
      |> Enum.flat_map(fn {gate, index} ->
        if valid_required_gate?(gate),
          do: [],
          else: [required_gates: "gate #{index} requires name, command, and positive timeout_ms"]
      end)
    end

    defp valid_required_gate?(gate) when is_map(gate) do
      gate = Map.new(gate, fn {key, value} -> {to_string(key), value} end)

      present_string?(gate["name"]) and
        present_string?(gate["command"]) and
        positive_integer?(gate["timeout_ms"])
    end

    defp valid_required_gate?(_gate), do: false
    defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
    defp positive_integer?(value), do: is_integer(value) and value > 0
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
        [
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state
        ],
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
      field(:pre_start_commands, {:array, :string}, default: [])

      field(:approval_policy, StringOrMap, default: "never")

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      field(:rate_limit_gate_enabled, :boolean, default: true)
      field(:rate_limit_gate_5h_threshold_percent, :float, default: 5.0)
      field(:rate_limit_gate_7d_threshold_percent, :float, default: 3.0)
      field(:rate_limit_gate_post_reset_delay_ms, :integer, default: 1_200_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :pre_start_commands,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :rate_limit_gate_enabled,
          :rate_limit_gate_5h_threshold_percent,
          :rate_limit_gate_7d_threshold_percent,
          :rate_limit_gate_post_reset_delay_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_command_list(:pre_start_commands)
      |> normalize_approval_policy()
      |> validate_inclusion(
        :approval_policy,
        SymphonyElixir.Config.Schema.codex_approval_policies()
      )
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:rate_limit_gate_5h_threshold_percent,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )
      |> validate_number(:rate_limit_gate_7d_threshold_percent,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )
      |> validate_number(:rate_limit_gate_post_reset_delay_ms, greater_than_or_equal_to: 0)
    end

    defp normalize_approval_policy(changeset) do
      approval_policy =
        changeset
        |> get_field(:approval_policy)
        |> SymphonyElixir.Config.Schema.normalize_codex_approval_policy()

      put_change(changeset, :approval_policy, approval_policy)
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

  @spec defaults() :: map()
  def defaults do
    %__MODULE__{
      workflow: default_workflow_policy(),
      profiles: default_profiles()
    }
    |> to_external_config()
  end

  @spec to_external_config(%__MODULE__{}) :: map()
  def to_external_config(%__MODULE__{} = settings) do
    settings
    |> Ecto.embedded_dump(:json)
    |> normalize_keys()
    |> Map.update!("tracker", &Map.delete(&1, "api_key"))
    |> drop_nil_values()
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

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> RuntimeResolver.default_workspace_root(settings.workspace.root)
        |> RuntimeResolver.default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    SymphonyElixir.StateName.normalize(state_name)
  end

  @doc false
  @spec workflow_profile_for_state(%__MODULE__{}, String.t() | nil) :: String.t() | nil
  def workflow_profile_for_state(%__MODULE__{workflow: workflow}, state_name)
      when is_binary(state_name) do
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
  def human_review_state?(%__MODULE__{workflow: workflow}, state_name)
      when is_binary(state_name) do
    normalized_state = normalize_issue_state(String.trim(state_name))

    workflow
    |> Map.get("human_review_states", [])
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.member?(normalized_state)
  end

  def human_review_state?(_settings, _state_name), do: false

  @doc false
  @spec workflow_allowed_updates(%__MODULE__{}, String.t() | nil) :: map()
  def workflow_allowed_updates(%__MODULE__{profiles: profiles}, profile)
      when is_binary(profile) do
    profiles
    |> get_in([profile, "allowed_updates"])
    |> case do
      updates when is_map(updates) -> updates
      _ -> %{}
    end
  end

  def workflow_allowed_updates(_settings, _profile), do: %{}

  @doc false
  @spec codex_approval_policies() :: [String.t()]
  def codex_approval_policies, do: @codex_approval_policies

  @doc false
  @spec normalize_codex_approval_policy(term()) :: String.t()
  def normalize_codex_approval_policy(nil), do: "never"
  def normalize_codex_approval_policy(""), do: "never"

  def normalize_codex_approval_policy(value) when is_binary(value) do
    String.trim(value)
  end

  def normalize_codex_approval_policy(value) when is_map(value) do
    if map_size(value) == 0, do: "never", else: "__invalid_map__"
  end

  def normalize_codex_approval_policy(_value), do: "__invalid__"

  @doc false
  @spec generated_project_bootstrap_commands(%__MODULE__{}) :: String.t() | nil
  def generated_project_bootstrap_commands(%__MODULE__{project: %Project{} = project}) do
    ProjectCommands.generated_project_bootstrap_commands(project)
  end

  def generated_project_bootstrap_commands(_settings), do: nil

  @doc false
  @spec project_setup_commands(%__MODULE__{}) :: String.t() | nil
  def project_setup_commands(%__MODULE__{project: %Project{} = project}) do
    ProjectCommands.project_setup_commands(project)
  end

  def project_setup_commands(_settings), do: nil

  @doc false
  @spec generated_before_remove_hook(%__MODULE__{}) :: String.t() | nil
  def generated_before_remove_hook(%__MODULE__{project: %Project{} = project}) do
    ProjectCommands.generated_before_remove_hook(project)
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
      | api_key: RuntimeResolver.env_secret("LINEAR_API_KEY"),
        assignee:
          RuntimeResolver.resolve_secret_setting(
            settings.tracker.assignee,
            System.get_env("LINEAR_ASSIGNEE")
          )
    }

    workspace = %{
      settings.workspace
      | root: RuntimeResolver.resolve_path_value(settings.workspace.root, %Workspace{}.root),
        repository_base_root: RuntimeResolver.resolve_optional_path_value(settings.workspace.repository_base_root),
        worktree_base_root: RuntimeResolver.resolve_optional_path_value(settings.workspace.worktree_base_root)
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_codex_approval_policy(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    workflow = normalize_workflow_policy(settings.workflow)
    profiles = normalize_profiles(settings.profiles)

    %{
      settings
      | tracker: tracker,
        workspace: workspace,
        codex: codex,
        workflow: workflow,
        profiles: profiles
    }
  end

  @doc false
  @spec default_workflow_policy() :: map()
  def default_workflow_policy do
    %{
      "states" => %{
        "Refining" => %{"profile" => "refinement"},
        "Ready" => %{"profile" => "implementation"},
        "In Progress" => %{"profile" => "implementation"}
      },
      "human_review_states" => ["Needs Refinement Review", "Ready to Merge", "Blocked"],
      "allowed_transitions" => [
        %{
          "from" => "Refining",
          "to" => "Needs Refinement Review",
          "actor" => "codex",
          "profile" => "refinement"
        },
        %{"from" => "Needs Refinement Review", "to" => "Ready", "actor" => "human"},
        %{"from" => "Needs Refinement Review", "to" => "Refining", "actor" => "human"},
        %{
          "from" => "Ready",
          "to" => "In Progress",
          "actor" => "codex",
          "profile" => "implementation"
        },
        %{
          "from" => "In Progress",
          "to" => "Ready to Merge",
          "actor" => "codex",
          "profile" => "implementation"
        },
        %{"from" => "Ready to Merge", "to" => "In Progress", "actor" => "human"},
        %{"from" => "Refining", "to" => "Blocked", "actor" => "symphony"},
        %{"from" => "Ready", "to" => "Blocked", "actor" => "symphony"},
        %{"from" => "In Progress", "to" => "Blocked", "actor" => "symphony"},
        %{"from" => "Blocked", "to" => "Ready", "actor" => "human"},
        %{"from" => "Blocked", "to" => "Needs Refinement Review", "actor" => "human"},
        %{"from" => "Blocked", "to" => "Canceled", "actor" => "human"}
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
            "Workflow profile: {{ workflow.profile_name }}\n\nRead the task and recent Linear comments before changing code. Implement, validate, commit, and push the exact Linear branchName. Post the final result, comment, and references, then explicitly request Ready to Merge. Symphony owns initial PR creation and renders its body from result.completed and result.validation under docs/pull-request-body.md. After human change requests return the issue to In Progress, update the same branch and PR before requesting Ready to Merge again."
        },
        "allowed_updates" => %{
          "description" => false,
          "comment" => true,
          "result" => true,
          "target_states" => ["In Progress", "Ready to Merge"]
        }
      },
      "nap" => %{
        "name" => "Nap audit",
        "executor" => %{"type" => "codex_agent"},
        "prompt" => %{
          "mode" => "replace",
          "template" =>
            "Workflow profile: nap\n\nRead the repository and project documentation. Lower code complexity by finding three categories of problems:\n\n1. Redundancy: repeated logic, near-duplicate functions, and copied blocks; redundant error handling, including repeated rescue/retry/wrap, defensive re-validation of already-validated data, and catch-all rescues that hide real failures; and redundant gating, including redundant feature flags, conditions that can never be false, and duplicated permission or capability checks across layers.\n2. Unreasonable mutual dependencies: incidental coupling, cyclic module dependencies, god modules, hidden shared state (ETS, globals, or the process dictionary), string-discriminated behavior, dual representation of one fact, and indirection layers with only one implementation.\n3. Dead weight: speculative abstractions, unread config keys, compatibility shims, and commented-out code.\n\nBefore reviewing, run a mechanical scan pre-step:\n- `mix xref graph` for unconsumed exports and functions.\n- `mix deps.tree` plus dependency-unused checks.\n- Credo duplicate-code and cyclomatic-complexity checks.\n- `mix dialyzer` for dead code such as `unused_fun`; OTP28 `unused_fun` has known false positives, so manually re-check the output.\nTool output is evidence, not a verdict; pair it with manual review.\n\nAudit these additional dimensions:\n- Stale exemption lists: `.dialyzer_ignore.exs`, Credo exemptions, `@tag :skip` tests, and disabled lint rules. Does the covered code still exist? Can an entry be tightened or the entire baseline dropped?\n- Unconsumed public APIs and events: public exports, `GenServer.call` or `GenServer.cast`, and event topics with no real consumer, backed by `mix xref graph`.\n- Hand-maintained documentation whose source of truth already exists in code, including config keys derivable from `schema.ex`, module lists, and indexes. Archive stale documentation instead of physically deleting it.\n- Gate-then-zero fix directions: introduce a gate, zero the debt, then drop the exemption baseline instead of doing one-off cleanup.\n\nFor every candidate, explicitly evaluate it against each of these Linus & Carmack criteria. State which criterion it violates and why:\n- Linus: remove complexity, keep good taste — making the system simpler is better than making it more elaborate; reject architecture-astronaut abstractions; code must earn its place.\n- Linus: talk is cheap, show me the code — prefer concrete, working, minimal changes over design essays.\n- Carmack: minimize the number of things that can go wrong — every flag, abstraction, and catch-all is another possible failure; do not represent one fact twice.\n- Carmack: hard to make simple is still worth it — hard-to-understand code is hard to make correct; simplify it instead of documenting around it.\n- Explicit errors over silent tolerance — failures must be visible and typed; never swallow a crash merely to keep a pipeline alive without a record.\n\nApply anti-false-positive discipline. Re-check every mechanical result manually, especially OTP28 dialyzer `unused_fun`. Distinguish pure deletion from reorganization or migration: if a capability is still used but misplaced, propose reorganization. For uncertain candidates, write Keep as-is instead of noise.\n\nThis profile proposes deletion or optimization directions; it does not delete. Do not modify code. Do not modify documentation. Do not create commits or pull requests. For every distinct problem that violates at least one criterion, create one Backlog Linear issue through the restricted issue creation tool. Each issue must include a concise title, evidence (file/line or code excerpt), the discovery path (mechanical scan output or manual review), the violated criterion and why, complexity impact, a fix direction that reduces complexity, and a verification path proving behavior remains unchanged after removal (`make all`, targeted tests, or `mix dialyzer`)."
        },
        "allowed_updates" => %{
          "description" => false,
          "comment" => false,
          "result" => false,
          "target_states" => []
        }
      },
      "day_dreaming" => %{
        "name" => "Day dreaming",
        "executor" => %{"type" => "codex_agent"},
        "prompt" => %{
          "mode" => "replace",
          "template" =>
            "Workflow profile: day_dreaming\n\nRead the existing code, README, architecture docs, long-term direction docs, and other relevant canonical documentation. Compare implementation reality with product direction and identify useful features or optimization opportunities that should be developed next. Every opportunity must be supported by evidence from code or documentation, align with the long-term direction, and not duplicate an existing Backlog issue.\n\nDo not modify code. Do not modify documentation. Do not create commits or pull requests. For every distinct product or engineering opportunity, create one Backlog Linear issue through the restricted issue creation tool with a concise title, evidence from code/docs, why it matters, suggested direction, and rough impact."
        },
        "allowed_updates" => %{
          "description" => false,
          "comment" => false,
          "result" => false,
          "target_states" => []
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
      WorkflowContract.workflow_errors(workflow, profiles, tracker)

    profile_errors =
      WorkflowContract.profile_errors(profiles)

    Enum.reduce(workflow_errors, changeset, &add_error(&2, :workflow, &1))
    |> then(fn changeset ->
      Enum.reduce(profile_errors, changeset, &add_error(&2, :profiles, &1))
    end)
  end

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

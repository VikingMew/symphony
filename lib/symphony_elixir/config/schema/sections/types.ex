# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Config.Schema.Sections.Types do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      alias SymphonyElixir.Config.Schema.{
        Agent,
        Analytics,
        Codex,
        Hooks,
        Observability,
        Polling,
        Project,
        Server,
        StringOrMap,
        Tracker,
        Worker,
        Workspace
      }

      use Ecto.Schema

      import Ecto.Changeset

      alias SymphonyElixir.Codex.ModelCatalog
      alias SymphonyElixir.Config.{CodexCommand, ProjectCommands, RuntimeResolver, WorkflowContract}

      @primary_key false

      @type t :: %__MODULE__{}

      @codex_approval_policies ["untrusted", "on-failure", "on-request", "granular", "never"]

      defmodule StringOrMap do
        @moduledoc false
        @behaviour Ecto.Type

        @spec type() :: :map
        def type do
          :map
        end

        @spec embed_as(term()) :: :self
        def embed_as(_format) do
          :self
        end

        @spec equal?(term(), term()) :: boolean()
        def equal?(left, right) do
          left == right
        end

        @spec cast(term()) :: {:ok, String.t() | map()} | :error
        def cast(value) when is_binary(value) or is_map(value) do
          {:ok, value}
        end

        def cast(_value) do
          :error
        end

        @spec load(term()) :: {:ok, String.t() | map()} | :error
        def load(value) when is_binary(value) or is_map(value) do
          {:ok, value}
        end

        def load(_value) do
          :error
        end

        @spec dump(term()) :: {:ok, String.t() | map()} | :error
        def dump(value) when is_binary(value) or is_map(value) do
          {:ok, value}
        end

        def dump(_value) do
          :error
        end
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
          field(:active_states, {:array, :string}, default: ["Todo", "Ready", "In Progress"])

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
            if is_binary(value) and String.trim(value) == "" do
              [{field, "must not be blank"}]
            else
              []
            end
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
            if is_binary(value) and String.trim(value) == "" do
              [{field, "must not be blank"}]
            else
              []
            end
          end)
        end

        defp validate_command_list(changeset, field) do
          validate_change(changeset, field, fn ^field, commands ->
            Enum.flat_map(commands || [], &command_error(field, &1))
          end)
        end

        defp command_error(field, command) when is_binary(command) do
          if String.trim(command) == "" do
            [{field, "commands must not be blank"}]
          else
            []
          end
        end

        defp command_error(field, _command) do
          [{field, "commands must be strings"}]
        end

        defp validate_required_gates(changeset) do
          validate_change(changeset, :required_gates, &required_gate_errors/2)
        end

        defp required_gate_errors(:required_gates, gates) do
          gates
          |> Enum.with_index()
          |> Enum.flat_map(fn {gate, index} ->
            if valid_required_gate?(gate) do
              []
            else
              [required_gates: "gate #{index} requires name, command, and positive timeout_ms"]
            end
          end)
        end

        defp valid_required_gate?(gate) when is_map(gate) do
          gate = Map.new(gate, fn {key, value} -> {to_string(key), value} end)

          present_string?(gate["name"]) and
            present_string?(gate["command"]) and
            positive_integer?(gate["timeout_ms"])
        end

        defp valid_required_gate?(_gate) do
          false
        end

        defp present_string?(value) do
          is_binary(value) and String.trim(value) != ""
        end

        defp positive_integer?(value) do
          is_integer(value) and value > 0
        end
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

        @primary_key false
        embedded_schema do
          field(:max_turns, :integer, default: 20)
          field(:max_retry_backoff_ms, :integer, default: 300_000)
          field(:max_failure_retries, :integer, default: 3)
        end

        @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
        def changeset(schema, attrs) do
          schema
          |> cast(
            attrs,
            [:max_turns, :max_retry_backoff_ms, :max_failure_retries],
            empty_values: []
          )
          |> validate_number(:max_turns, greater_than: 0)
          |> validate_number(:max_retry_backoff_ms, greater_than: 0)
          |> validate_number(:max_failure_retries, greater_than_or_equal_to: 0)
        end
      end

      defmodule Codex do
        @moduledoc false
        use Ecto.Schema
        import Ecto.Changeset

        @primary_key false
        embedded_schema do
          field(:command, :string, default: "codex app-server")
          field(:model, :string)
          field(:reasoning_effort, :string)
          field(:pre_start_commands, {:array, :string}, default: [])

          field(:approval_policy, StringOrMap, default: "never")

          field(:thread_sandbox, :string, default: "workspace-write")
          field(:turn_sandbox_policy, :map)
          field(:turn_timeout_ms, :integer, default: 3_600_000)
          field(:read_timeout_ms, :integer, default: 5000)
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
              :model,
              :reasoning_effort,
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
          |> validate_command_overrides()
          |> normalize_optional_selector(:model)
          |> normalize_optional_selector(:reasoning_effort)
          |> validate_model_and_reasoning_effort()
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

        defp validate_command_overrides(changeset) do
          case get_field(changeset, :command) do
            command when is_binary(command) ->
              case CodexCommand.override_fields(command) do
                [] -> changeset
                fields -> add_error(changeset, :command, CodexCommand.validation_message(fields))
              end

            _missing ->
              changeset
          end
        end

        defp normalize_approval_policy(changeset) do
          approval_policy =
            changeset
            |> get_field(:approval_policy)
            |> SymphonyElixir.Config.Schema.normalize_codex_approval_policy()

          put_change(changeset, :approval_policy, approval_policy)
        end

        defp normalize_optional_selector(changeset, field) do
          case get_field(changeset, field) do
            value when is_binary(value) ->
              value = String.trim(value)

              put_change(
                changeset,
                field,
                if value == "" do
                  nil
                else
                  value
                end
              )

            _value ->
              changeset
          end
        end

        defp validate_model_and_reasoning_effort(changeset) do
          model = get_field(changeset, :model)
          effort = get_field(changeset, :reasoning_effort)

          changeset
          |> validate_model(model)
          |> validate_reasoning_effort(model, effort)
        end

        defp validate_model(changeset, nil) do
          changeset
        end

        defp validate_model(changeset, model) do
          if ModelCatalog.model?(model) do
            changeset
          else
            add_error(changeset, :model, "must be one of: #{Enum.join(ModelCatalog.model_ids(), ", ")}")
          end
        end

        defp validate_reasoning_effort(changeset, _model, nil) do
          changeset
        end

        defp validate_reasoning_effort(changeset, nil, effort) do
          if ModelCatalog.reasoning_effort?(effort) do
            changeset
          else
            add_error(
              changeset,
              :reasoning_effort,
              "must be one of: #{Enum.join(ModelCatalog.reasoning_efforts(), ", ")}"
            )
          end
        end

        defp validate_reasoning_effort(changeset, model, effort) do
          cond do
            not ModelCatalog.reasoning_effort?(effort) ->
              add_error(
                changeset,
                :reasoning_effort,
                "must be one of: #{Enum.join(ModelCatalog.reasoning_efforts(), ", ")}"
              )

            ModelCatalog.model?(model) and not ModelCatalog.supports_reasoning_effort?(model, effort) ->
              add_error(
                changeset,
                :reasoning_effort,
                "must be one of #{Enum.join(ModelCatalog.reasoning_efforts_for_model(model), ", ")} for model #{model}"
              )

            true ->
              changeset
          end
        end

        defp validate_command_list(changeset, field) do
          validate_change(changeset, field, fn ^field, commands ->
            Enum.flat_map(commands || [], &command_error(field, &1))
          end)
        end

        defp command_error(field, command) when is_binary(command) do
          if String.trim(command) == "" do
            [{field, "commands must not be blank"}]
          else
            []
          end
        end

        defp command_error(field, _command) do
          [{field, "commands must be strings"}]
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
          field(:refresh_ms, :integer, default: 1000)
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

      defmodule Analytics do
        @moduledoc false
        use Ecto.Schema
        import Ecto.Changeset

        @primary_key false
        @type t :: %__MODULE__{}
        embedded_schema do
          field(:refinement_rounds_average_max, :float)
          field(:first_handoff_observed_return_rate_max, :float)
          field(:blocked_rate_max, :float)
          field(:latest_description_length_min, :integer)
          field(:rework_rate_max, :float)
          field(:per_issue_total_tokens_max, :integer)
        end

        @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
        def changeset(schema, attrs) do
          schema
          |> cast(attrs, [
            :refinement_rounds_average_max,
            :first_handoff_observed_return_rate_max,
            :blocked_rate_max,
            :latest_description_length_min,
            :rework_rate_max,
            :per_issue_total_tokens_max
          ])
          |> validate_number(:refinement_rounds_average_max, greater_than_or_equal_to: 0)
          |> validate_number(:first_handoff_observed_return_rate_max,
            greater_than_or_equal_to: 0,
            less_than_or_equal_to: 1
          )
          |> validate_number(:blocked_rate_max, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
          |> validate_number(:latest_description_length_min, greater_than_or_equal_to: 0)
          |> validate_number(:rework_rate_max, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
          |> validate_number(:per_issue_total_tokens_max, greater_than_or_equal_to: 0)
        end
      end
    end
  end
end

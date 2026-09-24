# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Config.Schema.Sections.Parsing do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import Ecto.Changeset

      alias SymphonyElixir.Codex.ModelCatalog
      alias SymphonyElixir.Config.{CodexCommand, ProjectCommands, RuntimeResolver, WorkflowContract}

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
        embeds_one(:analytics, Analytics, on_replace: :update, defaults_to_struct: true)
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
        |> Map.put("workflow", default_workflow_policy())
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

      def workflow_profile_for_state(_settings, _state_name) do
        nil
      end

      @doc false
      @spec workflow_profile(%__MODULE__{}, String.t() | nil) :: map()
      def workflow_profile(%__MODULE__{profiles: profiles}, profile) when is_binary(profile) do
        case Map.get(profiles, profile) do
          %{} = policy -> policy
          _ -> %{}
        end
      end

      def workflow_profile(_settings, _profile) do
        %{}
      end

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

      def human_review_state?(_settings, _state_name) do
        false
      end

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

      def workflow_allowed_updates(_settings, _profile) do
        %{}
      end

      @doc false
      @spec codex_approval_policies() :: [String.t()]
      def codex_approval_policies do
        @codex_approval_policies
      end

      @doc false
      @spec normalize_codex_approval_policy(term()) :: String.t()
      def normalize_codex_approval_policy(nil) do
        "never"
      end

      def normalize_codex_approval_policy("") do
        "never"
      end

      def normalize_codex_approval_policy(value) when is_binary(value) do
        String.trim(value)
      end

      def normalize_codex_approval_policy(value) when is_map(value) do
        if map_size(value) == 0 do
          "never"
        else
          "__invalid_map__"
        end
      end

      def normalize_codex_approval_policy(_value) do
        "__invalid__"
      end

      @doc false
      @spec generated_project_bootstrap_commands(%__MODULE__{}) :: String.t() | nil
      def generated_project_bootstrap_commands(%__MODULE__{project: %Project{} = project}) do
        ProjectCommands.generated_project_bootstrap_commands(project)
      end

      def generated_project_bootstrap_commands(_settings) do
        nil
      end

      @doc false
      @spec project_setup_commands(%__MODULE__{}) :: String.t() | nil
      def project_setup_commands(%__MODULE__{project: %Project{} = project}) do
        ProjectCommands.project_setup_commands(project)
      end

      def project_setup_commands(_settings) do
        nil
      end

      @doc false
      @spec generated_before_remove_hook(%__MODULE__{}) :: String.t() | nil
      def generated_before_remove_hook(%__MODULE__{project: %Project{} = project}) do
        ProjectCommands.generated_before_remove_hook(project)
      end

      def generated_before_remove_hook(_settings) do
        nil
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
        |> cast_embed(:analytics, with: &Analytics.changeset/2)
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

        profiles = normalize_profiles(settings.profiles)

        %{
          settings
          | tracker: tracker,
            workspace: workspace,
            codex: codex,
            workflow: default_workflow_policy(),
            profiles: profiles
        }
      end

      @doc false
      @spec default_workflow_policy() :: map()
    end
  end
end

defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from the active workflow package.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{setup_required: true}} ->
        {:error, :setup_required}

      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec workflow_policy() :: map()
  def workflow_policy do
    settings!().workflow
  end

  @spec workflow_profile_for_state(String.t() | nil) :: String.t() | nil
  def workflow_profile_for_state(state_name) do
    Schema.workflow_profile_for_state(settings!(), state_name)
  end

  @spec workflow_profile(String.t() | nil) :: map()
  def workflow_profile(profile) do
    Schema.workflow_profile(settings!(), profile)
  end

  @spec workflow_executor_for_state(String.t() | nil) :: String.t() | nil
  def workflow_executor_for_state(state_name) do
    Schema.workflow_executor_for_state(settings!(), state_name)
  end

  @spec human_review_state?(String.t() | nil) :: boolean()
  def human_review_state?(state_name) do
    Schema.human_review_state?(settings!(), state_name)
  end

  @spec workflow_allowed_updates(String.t() | nil) :: map()
  def workflow_allowed_updates(profile) do
    Schema.workflow_allowed_updates(settings!(), profile)
  end

  @spec generated_after_create_hook() :: String.t() | nil
  def generated_after_create_hook do
    Schema.generated_after_create_hook(settings!())
  end

  @spec generated_before_remove_hook() :: String.t() | nil
  def generated_before_remove_hook do
    Schema.generated_before_remove_hook(settings!())
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    {:ok, %{prompt_template: prompt}} = Workflow.current()
    if String.trim(prompt) == "", do: @default_prompt_template, else: prompt
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec execution_mode() :: :centralized | :worker
  def execution_mode do
    case Application.get_env(:symphony_elixir, :execution_mode) || System.get_env("SYMPHONY_EXECUTION_MODE") || :centralized do
      :worker -> :worker
      "worker" -> :worker
      _ -> :centralized
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_settings(settings)
    end
  end

  @spec validate_settings(Schema.t()) :: :ok | {:error, term()}
  def validate_settings(%Schema{} = settings), do: validate_semantics(settings)

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_tracker(settings.tracker) do
      validate_project(settings.project)
    end
  end

  defp validate_project(%{repository_url: repository_url}) do
    if blank?(repository_url), do: {:error, :missing_project_repository_url}, else: :ok
  end

  defp validate_project(_project), do: {:error, :missing_project_repository_url}

  defp validate_tracker(%{kind: nil}), do: {:error, :missing_tracker_kind}

  defp validate_tracker(%{kind: kind}) when kind != "linear" do
    {:error, {:unsupported_tracker_kind, kind}}
  end

  defp validate_tracker(%{api_key: api_key}) when not is_binary(api_key) do
    {:error, :missing_linear_api_token}
  end

  defp validate_tracker(%{endpoint: endpoint}) when not is_binary(endpoint) do
    {:error, :missing_linear_endpoint}
  end

  defp validate_tracker(%{project_slug: project_slug}) when not is_binary(project_slug) do
    {:error, :missing_linear_project_slug}
  end

  defp validate_tracker(tracker) do
    cond do
      blank?(tracker.endpoint) -> {:error, :missing_linear_endpoint}
      blank?(tracker.project_slug) -> {:error, :missing_linear_project_slug}
      true -> :ok
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp format_config_error(reason) do
    case reason do
      :setup_required ->
        "No active workflow is configured. Open /settings/workflow to create one."

      {:invalid_workflow_config, message} ->
        "Invalid workflow config: #{message}"
    end
  end
end

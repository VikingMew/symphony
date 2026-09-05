defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from the current workflow.
  """

  alias SymphonyElixir.{Config.Schema, Text, Workflow, WorkflowStore}

  @workflow_context_key :symphony_workflow_context

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

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case current_workflow() do
      {:ok, %{setup_required: true}} ->
        {:error, :setup_required}

      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, :no_active_workflow} ->
        {:error, :setup_required}

      {:error, reason} ->
        {:error, reason}
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

  @spec with_workflow_context(Workflow.loaded_workflow(), (-> result)) :: result when result: term()
  def with_workflow_context(%{config: _config} = workflow, fun) when is_function(fun, 0) do
    previous = Process.get(@workflow_context_key)
    Process.put(@workflow_context_key, workflow)

    try do
      fun.()
    after
      if is_nil(previous) do
        Process.delete(@workflow_context_key)
      else
        Process.put(@workflow_context_key, previous)
      end
    end
  end

  @spec current_workflow() ::
          {:ok, Workflow.loaded_workflow()}
          | {:error,
             :missing_project_context
             | :no_active_workflow
             | :repo_unavailable
             | {:query_failed, term()}}
  def current_workflow do
    case Process.get(@workflow_context_key) do
      %{config: _config} = workflow -> {:ok, workflow}
      _ -> WorkflowStore.current()
    end
  end

  @spec panel_max_concurrent_agents() :: pos_integer()
  def panel_max_concurrent_agents do
    :symphony_elixir
    |> Application.fetch_env!(:panel)
    |> Keyword.fetch!(:max_concurrent_agents)
  end

  @spec workflow_policy() :: map()
  def workflow_policy do
    settings!().workflow
  end

  @spec required_gates() :: [map()]
  def required_gates, do: settings!().project.required_gates

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

  @spec generated_project_bootstrap_commands() :: String.t() | nil
  def generated_project_bootstrap_commands do
    Schema.generated_project_bootstrap_commands(settings!())
  end

  @spec project_setup_commands() :: String.t() | nil
  def project_setup_commands do
    Schema.project_setup_commands(settings!())
  end

  @spec generated_before_remove_hook() :: String.t() | nil
  def generated_before_remove_hook do
    Schema.generated_before_remove_hook(settings!())
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    {:ok, %{prompt_template: prompt}} = current_workflow()
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

  defp validate_semantics(settings) do
    with :ok <- validate_tracker(settings.tracker) do
      validate_project(settings.project)
    end
  end

  defp validate_project(%{repository_url: repository_url}) do
    if Text.blank?(repository_url), do: {:error, :missing_project_repository_url}, else: :ok
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
      Text.blank?(tracker.endpoint) -> {:error, :missing_linear_endpoint}
      Text.blank?(tracker.project_slug) -> {:error, :missing_linear_project_slug}
      true -> :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      :setup_required ->
        "No workflow is configured. Open /settings/workflow to create one."

      {:invalid_workflow_config, message} ->
        "Invalid workflow config: #{message}"

      :repo_unavailable ->
        "Runtime configuration unavailable: database repository is unavailable."

      :missing_project_context ->
        "Runtime configuration unavailable: explicit project context is required."

      {:query_failed, query_reason} ->
        "Runtime configuration unavailable: database query failed: #{inspect(query_reason)}"
    end
  end
end

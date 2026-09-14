defmodule SymphonyElixir.Config.WorkflowScopes do
  @moduledoc """
  Defines the durable instance and project workflow slices.
  """

  alias SymphonyElixir.Config.Schema

  @instance_sections ~w(polling workspace hooks agent codex observability analytics server worker profiles)
  @project_sections ~w(tracker project)
  @instance_value_keys ~w(config prompt_body)
  @project_fields %{
    "tracker" => ~w(kind endpoint project_slug assignee active_states terminal_states),
    "project" => ~w(repository_url default_branch checkout_depth source_strategy worktree_fetch worktree_cleanup required_gates setup_commands cleanup_commands)
  }
  @instance_modules %{
    "polling" => Schema.Polling,
    "workspace" => Schema.Workspace,
    "hooks" => Schema.Hooks,
    "agent" => Schema.Agent,
    "codex" => Schema.Codex,
    "observability" => Schema.Observability,
    "analytics" => Schema.Analytics,
    "server" => Schema.Server,
    "worker" => Schema.Worker
  }

  @type scope :: :instance | :project
  @type scope_error ::
          {:out_of_scope_workflow_fields, scope(), [String.t()]}
          | {:duplicate_workflow_fields, scope(), [String.t()]}
          | {:invalid_instance_workflow, term()}
          | {:invalid_project_workflow, term()}

  @type instance_workflow :: %{config: map(), prompt_body: String.t()}

  @spec split_package(map(), String.t()) ::
          {:ok, instance_workflow(), map()} | {:error, scope_error() | term()}
  def split_package(config, prompt_body) when is_map(config) and is_binary(prompt_body) do
    with {:ok, config} <- canonicalize(config, :instance),
         instance_config = Map.take(config, @instance_sections),
         project_config = Map.take(config, @project_sections),
         :ok <- validate_combined_keys(config),
         {:ok, instance} <- new_instance(instance_config, prompt_body),
         :ok <- validate_project_config(project_config),
         {:ok, _settings} <- Schema.parse(compose_config(instance.config, project_config)) do
      {:ok, instance, project_config}
    end
  end

  @spec new_instance(map(), String.t()) :: {:ok, instance_workflow()} | {:error, scope_error() | term()}
  def new_instance(config, prompt_body) when is_map(config) and is_binary(prompt_body) do
    with {:ok, config} <- canonicalize(config, :instance),
         :ok <- validate_instance_config(config),
         {:ok, _settings} <- Schema.parse(compose_config(config, %{})) do
      {:ok, %{config: config, prompt_body: prompt_body}}
    end
  end

  @spec load_instance(map()) :: {:ok, instance_workflow()} | {:error, scope_error() | term()}
  def load_instance(value) when is_map(value) do
    with {:ok, value} <- canonicalize(value, :instance) do
      invalid = Map.keys(value) -- @instance_value_keys

      cond do
        invalid != [] ->
          {:error, {:out_of_scope_workflow_fields, :instance, Enum.sort(invalid)}}

        not is_map(Map.get(value, "config")) or not is_binary(Map.get(value, "prompt_body")) ->
          {:error, {:invalid_instance_workflow, :invalid_value}}

        true ->
          new_instance(Map.fetch!(value, "config"), Map.fetch!(value, "prompt_body"))
      end
    end
  end

  def load_instance(value), do: {:error, {:invalid_instance_workflow, value}}

  @spec dump_instance(instance_workflow()) :: map()
  def dump_instance(%{config: config, prompt_body: prompt_body}) do
    %{"config" => config, "prompt_body" => prompt_body}
  end

  @spec project_from_loaded(map()) :: {:ok, map()} | {:error, scope_error()}
  def project_from_loaded(%{config: config, prompt: prompt}) when is_map(config) and is_binary(prompt) do
    with :ok <- require_blank_project_prompt(prompt),
         {:ok, config} <- canonicalize(config, :project),
         :ok <- validate_project_config(config) do
      {:ok, config}
    end
  end

  @spec validate_project_config(map()) :: :ok | {:error, scope_error()}
  def validate_project_config(config) when is_map(config) do
    with {:ok, config} <- canonicalize(config, :project) do
      validate_section_fields(config, :project, @project_fields)
    end
  end

  @spec compose(instance_workflow(), map(), term()) ::
          {:ok, map()} | {:error, scope_error() | term()}
  def compose(%{config: instance_config, prompt_body: prompt_body}, project_config, project_id)
      when is_map(project_config) do
    with {:ok, instance_config} <- canonicalize(instance_config, :instance),
         {:ok, project_config} <- canonicalize(project_config, :project),
         :ok <- validate_instance_config(instance_config),
         :ok <- validate_project_config(project_config) do
      config = compose_config(instance_config, project_config)

      {:ok,
       %{
         config: config,
         prompt: prompt_body,
         prompt_template: prompt_body,
         project_id: project_id
       }}
    end
  end

  @spec combined(instance_workflow(), map()) :: {:ok, %{config: map(), prompt: String.t()}} | {:error, term()}
  def combined(%{config: instance_config, prompt_body: prompt_body}, project_config)
      when is_map(project_config) do
    with {:ok, instance_config} <- canonicalize(instance_config, :instance),
         {:ok, project_config} <- canonicalize(project_config, :project),
         :ok <- validate_instance_config(instance_config),
         :ok <- validate_project_config(project_config),
         config = compose_config(instance_config, project_config),
         {:ok, _settings} <- Schema.parse(config) do
      {:ok, %{config: config, prompt: prompt_body}}
    end
  end

  @spec instance_sections() :: [String.t()]
  def instance_sections, do: @instance_sections

  @spec project_sections() :: [String.t()]
  def project_sections, do: @project_sections

  defp validate_combined_keys(config) do
    allowed = @instance_sections ++ @project_sections ++ ["workflow"]
    invalid = Map.keys(config) -- allowed

    if invalid == [],
      do: :ok,
      else: {:error, {:out_of_scope_workflow_fields, :instance, Enum.sort(invalid)}}
  end

  defp validate_instance_config(config) do
    allowed_fields =
      Map.new(@instance_modules, fn {section, module} ->
        {section, module.__schema__(:fields) |> Enum.map(&Atom.to_string/1)}
      end)
      |> Map.put("profiles", :dynamic)

    validate_section_fields(config, :instance, allowed_fields)
  end

  defp validate_section_fields(config, scope, allowed_fields) do
    invalid_sections = Map.keys(config) -- Map.keys(allowed_fields)

    invalid_fields =
      Enum.flat_map(allowed_fields, fn
        {section, :dynamic} ->
          if is_map(section_value(config, section, %{})), do: [], else: [section]

        {section, allowed} ->
          case section_value(config, section) do
            nil -> []
            value when is_map(value) -> Enum.map(Map.keys(value) -- allowed, &"#{section}.#{&1}")
            _value -> [section]
          end
      end)

    case Enum.sort(invalid_sections ++ invalid_fields) do
      [] -> :ok
      invalid -> {:error, {:out_of_scope_workflow_fields, scope, invalid}}
    end
  end

  defp require_blank_project_prompt(prompt) do
    if String.trim(prompt) == "",
      do: :ok,
      else: {:error, {:out_of_scope_workflow_fields, :project, ["prompt_body"]}}
  end

  defp compose_config(instance_config, project_config) do
    instance_config
    |> Map.merge(project_config)
    |> Map.put("workflow", Schema.default_workflow_policy())
  end

  defp section_value(config, section, default \\ nil) do
    Map.get(config, section, default)
  end

  defp canonicalize(value, scope), do: canonicalize(value, scope, [])

  defp canonicalize(value, scope, path) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, &canonicalize_entry(&1, &2, scope, path))
  end

  defp canonicalize(value, scope, path) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, normalized} ->
      case canonicalize(item, scope, path) do
        {:ok, nested} -> {:cont, {:ok, [nested | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp canonicalize(value, _scope, _path), do: {:ok, value}

  defp canonicalize_entry({raw_key, raw_value}, {:ok, normalized}, scope, path) do
    key = to_string(raw_key)
    field_path = path ++ [key]

    if Map.has_key?(normalized, key) do
      {:halt, {:error, {:duplicate_workflow_fields, scope, [Enum.join(field_path, ".")]}}}
    else
      canonicalize_new_entry(raw_value, normalized, key, scope, field_path)
    end
  end

  defp canonicalize_new_entry(raw_value, normalized, key, scope, field_path) do
    case canonicalize(raw_value, scope, field_path) do
      {:ok, nested} -> {:cont, {:ok, Map.put(normalized, key, nested)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end
end

defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads a complete workflow package and prompt.

  Split package parsing supports `workflow.yml` for runtime/routing data and
  `profiles.yml` for agent profile settings plus the shared base prompt. The
  runtime source is the project's current workflow in PostgreSQL.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.WorkflowStore

  @workflow_config_file_names ["workflow.yml", "workflow.yaml"]
  @profiles_config_file_names ["profiles.yml", "profiles.yaml"]
  @setup_message "Create a workflow from the Web UI to start running agents."

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), "workflow.yml")
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          required(:config) => map(),
          required(:prompt) => String.t(),
          required(:prompt_template) => String.t(),
          optional(:project_id) => term(),
          optional(:setup_message) => String.t(),
          optional(:setup_required) => boolean()
        }

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    if split_package_available?(path) do
      load_split_package(path)
    else
      case File.read(path) do
        {:ok, content} ->
          parse_content(content)

        {:error, reason} ->
          {:error, {:missing_workflow_file, path, reason}}
      end
    end
  end

  @spec setup_required_workflow(non_neg_integer() | nil) :: loaded_workflow()
  def setup_required_workflow(port \\ nil) do
    defaults = Schema.defaults()

    %{
      config: %{
        "tracker" => defaults["tracker"] |> Map.put("kind", "linear") |> Map.put("project_slug", ""),
        "polling" => defaults["polling"],
        "server" => Map.put(defaults["server"], "port", port),
        "workspace" => defaults["workspace"],
        "agent" => Map.take(defaults["agent"], ["max_concurrent_agents", "max_turns"]),
        "codex" => Map.take(defaults["codex"], ["command", "pre_start_commands", "approval_policy", "thread_sandbox"]),
        "workflow" => defaults["workflow"],
        "profiles" => defaults["profiles"]
      },
      prompt: "",
      prompt_template: "",
      setup_message: @setup_message,
      setup_required: true
    }
  end

  @spec parse_split_package(String.t(), String.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def parse_split_package(workflow_yaml, profiles_yaml) when is_binary(workflow_yaml) and is_binary(profiles_yaml) do
    with {:ok, workflow_config} <- parse_workflow_yaml(workflow_yaml),
         {:ok, profile_package} <- parse_profiles_yaml(profiles_yaml) do
      prompt = profile_package.base_prompt |> normalize_base_prompt() |> to_prompt_body()

      config =
        workflow_config
        |> Map.delete("profiles")
        |> Map.put("profiles", profile_package.profiles)

      {:ok,
       %{
         config: config,
         prompt: prompt,
         prompt_template: prompt
       }}
    end
  end

  @spec parse_workflow_yaml(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_workflow_yaml(workflow_yaml) when is_binary(workflow_yaml) do
    yaml_string_to_map(workflow_yaml, "workflow.yml")
  end

  @spec parse_profiles_yaml(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_profiles_yaml(profiles_yaml) when is_binary(profiles_yaml) do
    profiles_string_to_package(profiles_yaml, "profiles.yml")
  end

  @spec parse_settings_yaml(String.t()) :: {:ok, {:workflow, map()} | {:profiles, map()}} | {:error, term()}
  def parse_settings_yaml(yaml) when is_binary(yaml) do
    with {:ok, decoded} <- yaml_string_to_map(yaml, "settings import") do
      settings_yaml_package(decoded)
    end
  end

  @spec parse_content(String.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def parse_content(content) when is_binary(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  @spec to_markdown(map(), String.t()) :: String.t()
  def to_markdown(config, prompt) when is_map(config) and is_binary(prompt) do
    yaml = yaml_document(config)
    "---\n" <> String.trim_trailing(yaml) <> "\n---\n\n" <> String.trim(prompt) <> "\n"
  end

  defp yaml_document(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> yaml_entry(to_string(key), value, 0) end)
  end

  defp yaml_entry(key, value, indent) when is_map(value) and map_size(value) > 0 do
    spaces(indent) <> key <> ":\n" <> yaml_nested_map(value, indent + 2)
  end

  defp yaml_entry(key, value, indent) when is_list(value) do
    spaces(indent) <> key <> ": " <> yaml_inline(value)
  end

  defp yaml_entry(key, value, indent) do
    spaces(indent) <> key <> ": " <> yaml_scalar(value)
  end

  defp yaml_nested_map(map, indent) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> yaml_entry(to_string(key), value, indent) end)
  end

  defp yaml_inline(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_scalar/1) <> "]"
  end

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp yaml_scalar(value) when is_map(value), do: "{" <> Enum.map_join(value, ", ", fn {k, v} -> yaml_scalar(to_string(k)) <> ": " <> yaml_scalar(v) end) <> "}"
  defp yaml_scalar(value) when is_list(value), do: yaml_inline(value)
  defp yaml_scalar(value), do: inspect(to_string(value))

  defp spaces(count), do: String.duplicate(" ", count)

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp split_package_available?(path) do
    if split_package_path?(path) do
      path
      |> split_package_dir()
      |> workflow_config_path()
      |> case do
        nil -> false
        workflow_path -> File.regular?(workflow_path)
      end
    else
      false
    end
  end

  defp load_split_package(path) do
    dir = split_package_dir(path)

    with {:ok, workflow_path} <- required_workflow_config_path(dir),
         {:ok, workflow_config} <- yaml_file_to_map(workflow_path),
         {:ok, profile_package} <- load_profiles_config(dir) do
      prompt = profile_package.base_prompt |> normalize_base_prompt() |> to_prompt_body()

      config =
        workflow_config
        |> Map.delete("profiles")
        |> Map.put("profiles", profile_package.profiles)

      {:ok,
       %{
         config: config,
         prompt: prompt,
         prompt_template: prompt
       }}
    end
  end

  defp split_package_dir(path) do
    basename = Path.basename(path)

    if basename in (@workflow_config_file_names ++ @profiles_config_file_names),
      do: Path.dirname(path),
      else: path
  end

  defp split_package_path?(path) do
    basename = Path.basename(path)
    extension = Path.extname(path)

    basename in (@workflow_config_file_names ++ @profiles_config_file_names) or
      extension == ""
  end

  defp required_workflow_config_path(dir) do
    case workflow_config_path(dir) do
      nil -> {:error, {:missing_workflow_file, Path.join(dir, "workflow.yml"), :enoent}}
      path -> {:ok, path}
    end
  end

  defp workflow_config_path(dir), do: first_regular_path(dir, @workflow_config_file_names)
  defp profiles_config_path(dir), do: first_regular_path(dir, @profiles_config_file_names)

  defp first_regular_path(dir, names) do
    names
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.find(&File.regular?/1)
  end

  defp yaml_file_to_map(path) do
    case File.read(path) do
      {:ok, content} -> yaml_string_to_map(content, path)
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp yaml_string_to_map(content, label) when is_binary(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} ->
        if is_map(decoded), do: {:ok, decoded}, else: {:error, {:workflow_yaml_not_a_map, label}}

      {:error, %YamlElixir.ParsingError{} = reason} ->
        {:error, {:workflow_parse_error, reason}}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp load_profiles_config(dir) do
    case profiles_config_path(dir) do
      nil ->
        {:ok, %{profiles: %{}, base_prompt: nil}}

      path ->
        case File.read(path) do
          {:ok, content} -> profiles_string_to_package(content, path)
          {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
        end
    end
  end

  defp profiles_string_to_package(content, label) when is_binary(content) do
    with {:ok, decoded} <- yaml_string_to_map(content, label) do
      normalize_profiles_file(decoded, label)
    end
  end

  defp normalize_profiles_file(%{"profiles" => profiles} = package, _path) when is_map(profiles) do
    %{profiles: profiles, base_prompt: normalize_base_prompt(Map.get(package, "base_prompt"))}
    |> then(&{:ok, &1})
  end

  defp normalize_profiles_file(%{"profiles" => _profiles}, path), do: {:error, {:profiles_yaml_profiles_not_a_map, path}}

  defp normalize_profiles_file(_package, path), do: {:error, {:profiles_yaml_missing_profiles, path}}

  defp settings_yaml_package(decoded) do
    if profiles_yaml?(decoded), do: settings_profiles_package(decoded), else: {:ok, {:workflow, decoded}}
  end

  defp settings_profiles_package(decoded) do
    with {:ok, profile_package} <- normalize_profiles_file(decoded, "profiles.yml") do
      {:ok, {:profiles, profile_package}}
    end
  end

  defp profiles_yaml?(decoded) when is_map(decoded) do
    Map.has_key?(decoded, "profiles") or Map.has_key?(decoded, "base_prompt")
  end

  defp normalize_base_prompt(prompt) when is_binary(prompt), do: prompt
  defp normalize_base_prompt(_prompt), do: nil

  defp to_prompt_body(nil), do: ""
  defp to_prompt_body(prompt), do: String.trim(prompt)

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end

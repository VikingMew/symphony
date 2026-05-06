defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"
  @setup_prompt "Create a workflow from the Web UI to start running agents."

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
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
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_content(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec setup_required_workflow(non_neg_integer() | nil) :: loaded_workflow()
  def setup_required_workflow(port \\ nil) do
    %{
      config: %{
        "tracker" => %{
          "kind" => "memory",
          "active_states" => ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"],
          "terminal_states" => ["Canceled", "Cancelled", "Duplicate", "Done"]
        },
        "polling" => %{"interval_ms" => 30_000},
        "server" => %{"host" => "127.0.0.1", "port" => port},
        "agent" => %{"max_concurrent_agents" => 1, "max_turns" => 20},
        "codex" => %{"command" => "codex app-server", "thread_sandbox" => "workspace-write"}
      },
      prompt: @setup_prompt,
      prompt_template: @setup_prompt,
      setup_required: true
    }
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

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end

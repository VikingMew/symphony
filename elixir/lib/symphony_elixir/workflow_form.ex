defmodule SymphonyElixir.WorkflowForm do
  @moduledoc """
  Converts workflow packages to and from the structured `/workflows` draft form.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @type draft :: %{String.t() => term()}

  @spec from_raw(String.t()) :: {:ok, draft()} | {:error, term()}
  def from_raw(raw_workflow_md) when is_binary(raw_workflow_md) do
    with {:ok, workflow} <- Workflow.parse_content(raw_workflow_md) do
      {:ok, from_loaded(workflow)}
    end
  end

  @spec from_loaded(map()) :: draft()
  def from_loaded(%{config: config, prompt: prompt}) when is_map(config) and is_binary(prompt) do
    display_config = normalized_display_config(config)

    %{
      "tracker_project_slug" => get_string(display_config, ["tracker", "project_slug"], ""),
      "tracker_assignee" => get_string(display_config, ["tracker", "assignee"], ""),
      "active_states" => get_list_text(display_config, ["tracker", "active_states"]),
      "terminal_states" => get_list_text(display_config, ["tracker", "terminal_states"]),
      "polling_interval_ms" => get_integer_string(display_config, ["polling", "interval_ms"], 30_000),
      "project_repository_url" => get_string(display_config, ["project", "repository_url"], ""),
      "project_default_branch" => get_string(display_config, ["project", "default_branch"], "main"),
      "project_checkout_depth" => get_integer_string(display_config, ["project", "checkout_depth"], 1),
      "project_setup_commands" => get_list_text(display_config, ["project", "setup_commands"]),
      "project_cleanup_commands" => get_list_text(display_config, ["project", "cleanup_commands"]),
      "workspace_root" => get_string(display_config, ["workspace", "root"], "/tmp/symphony-workspaces"),
      "agent_max_concurrent_agents" => get_integer_string(display_config, ["agent", "max_concurrent_agents"], 1),
      "agent_max_turns" => get_integer_string(display_config, ["agent", "max_turns"], 20),
      "codex_command" => get_string(display_config, ["codex", "command"], "codex app-server"),
      "codex_thread_sandbox" => get_string(display_config, ["codex", "thread_sandbox"], "workspace-write"),
      "hook_after_create" => get_string(display_config, ["hooks", "after_create"], ""),
      "hook_before_run" => get_string(display_config, ["hooks", "before_run"], ""),
      "hook_after_run" => get_string(display_config, ["hooks", "after_run"], ""),
      "hook_before_remove" => get_string(display_config, ["hooks", "before_remove"], ""),
      "hook_timeout_ms" => get_integer_string(display_config, ["hooks", "timeout_ms"], 60_000),
      "profiles" => profiles_form(display_config),
      "workflow_states" => workflow_states_form(display_config),
      "human_review_states" => get_list_text(display_config, ["workflow", "human_review_states"]),
      "allowed_transitions" => get_in(display_config, ["workflow", "allowed_transitions"]) || [],
      "prompt_body" => prompt,
      "_base_config" => display_config
    }
  end

  @spec empty() :: draft()
  def empty do
    from_loaded(Workflow.setup_required_workflow())
  end

  @spec to_raw(draft()) :: {:ok, String.t()} | {:error, String.t()}
  def to_raw(draft) when is_map(draft) do
    with {:ok, config} <- to_config(draft) do
      {:ok, Workflow.to_markdown(config, Map.get(draft, "prompt_body", ""))}
    end
  end

  @spec to_config(draft()) :: {:ok, map()} | {:error, String.t()}
  def to_config(draft) when is_map(draft) do
    with {:ok, polling_interval_ms} <- parse_positive_integer(draft, "polling_interval_ms", "Polling interval"),
         {:ok, checkout_depth} <- parse_positive_integer(draft, "project_checkout_depth", "Checkout depth"),
         {:ok, max_agents} <- parse_positive_integer(draft, "agent_max_concurrent_agents", "Max agents"),
         {:ok, max_turns} <- parse_positive_integer(draft, "agent_max_turns", "Max turns"),
         {:ok, hook_timeout_ms} <- parse_positive_integer(draft, "hook_timeout_ms", "Hook timeout") do
      config =
        draft
        |> Map.get("_base_config", %{})
        |> put_path(["tracker", "kind"], "linear")
        |> put_path(["tracker", "endpoint"], linear_endpoint(draft))
        |> put_optional_path(["tracker", "api_key"], tracker_api_key(draft))
        |> put_optional_path(["tracker", "project_slug"], Map.get(draft, "tracker_project_slug", ""))
        |> put_optional_path(["tracker", "assignee"], Map.get(draft, "tracker_assignee", ""))
        |> put_path(["tracker", "active_states"], lines(Map.get(draft, "active_states", "")))
        |> put_path(["tracker", "terminal_states"], lines(Map.get(draft, "terminal_states", "")))
        |> put_path(["polling", "interval_ms"], polling_interval_ms)
        |> put_project(draft, checkout_depth)
        |> put_path(["workspace", "root"], Map.get(draft, "workspace_root", ""))
        |> put_path(["agent", "max_concurrent_agents"], max_agents)
        |> put_path(["agent", "max_turns"], max_turns)
        |> put_path(["codex", "command"], Map.get(draft, "codex_command", ""))
        |> put_path(["codex", "thread_sandbox"], Map.get(draft, "codex_thread_sandbox", ""))
        |> put_path(["hooks"], hooks_config(draft, hook_timeout_ms))
        |> put_path(["profiles"], profiles_config(draft))
        |> put_path(["workflow", "states"], workflow_states_config(draft))
        |> put_path(["workflow", "human_review_states"], lines(Map.get(draft, "human_review_states", "")))
        |> put_path(["workflow", "allowed_transitions"], transitions_config(draft))

      {:ok, config}
    end
  end

  @spec summary(draft()) :: map()
  def summary(draft) when is_map(draft) do
    %{
      tracker: tracker_kind(draft),
      project: blank_as_na(Map.get(draft, "tracker_project_slug", "")),
      repository: blank_as_na(Map.get(draft, "project_repository_url", "")),
      workspace: blank_as_na(Map.get(draft, "workspace_root", "")),
      active_states: lines(Map.get(draft, "active_states", "")) |> length(),
      terminal_states: lines(Map.get(draft, "terminal_states", "")) |> length(),
      setup_commands: lines(Map.get(draft, "project_setup_commands", "")) |> length(),
      hooks: hook_count(draft),
      profiles: map_size(Map.get(draft, "profiles", %{})),
      routed_states: map_size(Map.get(draft, "workflow_states", %{})),
      prompt_chars: String.length(Map.get(draft, "prompt_body", ""))
    }
  end

  @spec profile_options(draft()) :: [String.t()]
  def profile_options(draft) when is_map(draft) do
    draft
    |> Map.get("profiles", %{})
    |> Map.keys()
    |> Enum.sort()
  end

  defp profiles_form(config) do
    config
    |> get_in(["profiles"])
    |> case do
      profiles when is_map(profiles) ->
        Map.new(profiles, fn {id, profile} ->
          {to_string(id),
           %{
             "name" => get_string(profile, ["name"], to_string(id)),
             "executor_type" => get_string(profile, ["executor", "type"], "codex_agent"),
             "prompt_mode" => get_string(profile, ["prompt", "mode"], "extend"),
             "prompt_template" => get_string(profile, ["prompt", "template"], ""),
             "allow_description" => get_boolean_string(profile, ["allowed_updates", "description"], false),
             "allow_comment" => get_boolean_string(profile, ["allowed_updates", "comment"], true),
             "allow_result" => get_boolean_string(profile, ["allowed_updates", "result"], true),
             "target_states" => get_list_text(profile, ["allowed_updates", "target_states"]),
             "_base" => profile
           }}
        end)

      _ ->
        %{}
    end
  end

  defp workflow_states_form(config) do
    config
    |> get_in(["workflow", "states"])
    |> case do
      states when is_map(states) ->
        Map.new(states, fn {state, attrs} ->
          {to_string(state),
           %{
             "profile" => get_string(attrs, ["profile"], ""),
             "_base" => attrs
           }}
        end)

      _ ->
        %{}
    end
  end

  defp profiles_config(draft) do
    draft
    |> Map.get("profiles", %{})
    |> Map.new(fn {id, attrs} ->
      base = Map.get(attrs, "_base", %{})

      profile =
        base
        |> put_path(["name"], Map.get(attrs, "name", id))
        |> put_path(["executor", "type"], Map.get(attrs, "executor_type", "codex_agent"))
        |> put_path(["prompt", "mode"], Map.get(attrs, "prompt_mode", "extend"))
        |> put_path(["prompt", "template"], Map.get(attrs, "prompt_template", ""))
        |> put_path(["allowed_updates", "description"], truthy?(Map.get(attrs, "allow_description", "false")))
        |> put_path(["allowed_updates", "comment"], truthy?(Map.get(attrs, "allow_comment", "false")))
        |> put_path(["allowed_updates", "result"], truthy?(Map.get(attrs, "allow_result", "false")))
        |> put_path(["allowed_updates", "target_states"], lines(Map.get(attrs, "target_states", "")))

      {id, profile}
    end)
  end

  defp workflow_states_config(draft) do
    draft
    |> Map.get("workflow_states", %{})
    |> Map.new(fn {state, attrs} ->
      base = Map.get(attrs, "_base", %{})
      {state, put_path(base, ["profile"], Map.get(attrs, "profile", ""))}
    end)
  end

  defp transitions_config(draft) do
    draft
    |> Map.get("allowed_transitions", [])
    |> transition_entries()
    |> Enum.map(fn entry ->
      %{}
      |> put_optional_transition_value("from", Map.get(entry, "from"))
      |> put_optional_transition_value("to", Map.get(entry, "to"))
      |> put_optional_transition_value("actor", Map.get(entry, "actor"))
      |> put_optional_transition_value("profile", Map.get(entry, "profile"))
    end)
    |> Enum.reject(&empty_transition?/1)
  end

  defp transition_entries(entries) when is_list(entries), do: entries

  defp transition_entries(entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {index, _entry} -> parse_index(index) end)
    |> Enum.map(fn {_index, entry} -> entry end)
  end

  defp transition_entries(_entries), do: []

  defp parse_index(index) do
    case Integer.parse(to_string(index)) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp put_optional_transition_value(transition, key, value) do
    value = String.trim(to_string(value || ""))
    if value == "", do: transition, else: Map.put(transition, key, value)
  end

  defp empty_transition?(transition), do: map_size(transition) == 0

  defp hooks_config(draft, timeout_ms) do
    %{"timeout_ms" => timeout_ms}
    |> put_optional_path(["after_create"], Map.get(draft, "hook_after_create", ""))
    |> put_optional_path(["before_run"], Map.get(draft, "hook_before_run", ""))
    |> put_optional_path(["after_run"], Map.get(draft, "hook_after_run", ""))
    |> put_optional_path(["before_remove"], Map.get(draft, "hook_before_remove", ""))
  end

  defp hook_count(draft) do
    [
      Map.get(draft, "hook_after_create", ""),
      Map.get(draft, "hook_before_run", ""),
      Map.get(draft, "hook_after_run", ""),
      Map.get(draft, "hook_before_remove", "")
    ]
    |> Enum.reject(&(String.trim(to_string(&1 || "")) == ""))
    |> length()
  end

  defp tracker_kind(_draft), do: "linear"

  defp linear_endpoint(draft) do
    draft
    |> Map.get("_base_config", %{})
    |> get_string(["tracker", "endpoint"], "https://api.linear.app/graphql")
    |> case do
      "" -> "https://api.linear.app/graphql"
      endpoint -> endpoint
    end
  end

  defp tracker_api_key(draft) do
    draft
    |> Map.get("_base_config", %{})
    |> get_string(["tracker", "api_key"], "$LINEAR_API_KEY")
    |> case do
      "" -> "$LINEAR_API_KEY"
      api_key -> api_key
    end
  end

  defp put_project(config, draft, checkout_depth) do
    config
    |> put_optional_path(["project", "repository_url"], Map.get(draft, "project_repository_url", ""))
    |> put_optional_path(["project", "default_branch"], Map.get(draft, "project_default_branch", ""))
    |> put_path(["project", "checkout_depth"], checkout_depth)
    |> put_path(["project", "setup_commands"], lines(Map.get(draft, "project_setup_commands", "")))
    |> put_path(["project", "cleanup_commands"], lines(Map.get(draft, "project_cleanup_commands", "")))
  end

  defp normalized_display_config(config) do
    config = Workflow.normalize_legacy_tracker_config(config)

    case Schema.parse(config) do
      {:ok, settings} ->
        config
        |> put_path(["workflow"], settings.workflow)
        |> put_path(["profiles"], settings.profiles)

      {:error, _reason} ->
        config
    end
  end

  defp parse_positive_integer(draft, key, label) do
    value = Map.get(draft, key, "")

    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, "#{label} must be a positive integer"}
    end
  end

  defp get_string(config, path, default) do
    case get_in(config, path) do
      value when is_binary(value) -> value
      nil -> default
      value -> to_string(value)
    end
  end

  defp get_integer_string(config, path, default) do
    case get_in(config, path) do
      value when is_integer(value) -> Integer.to_string(value)
      value when is_binary(value) -> value
      _ -> Integer.to_string(default)
    end
  end

  defp get_boolean_string(config, path, default) do
    case get_in(config, path) do
      value when is_boolean(value) -> to_string(value)
      value when is_binary(value) -> value
      _ -> to_string(default)
    end
  end

  defp get_list_text(config, path) do
    config
    |> get_in(path)
    |> case do
      values when is_list(values) -> Enum.map_join(values, "\n", &to_string/1)
      _ -> ""
    end
  end

  defp lines(value) do
    value
    |> to_string()
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp put_optional_path(config, path, value) do
    if String.trim(to_string(value || "")) == "" do
      config
    else
      put_path(config, path, value)
    end
  end

  defp put_path(config, [key], value), do: Map.put(config, key, value)

  defp put_path(config, [key | rest], value) do
    child = Map.get(config, key, %{})
    Map.put(config, key, put_path(child, rest, value))
  end

  defp blank_as_na(value) do
    if String.trim(to_string(value || "")) == "", do: "n/a", else: value
  end

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_value), do: false
end

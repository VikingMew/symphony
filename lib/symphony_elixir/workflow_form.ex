defmodule SymphonyElixir.WorkflowForm do
  @moduledoc """
  Converts workflow packages to and from the structured `/settings/workflow` draft form.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @type draft :: %{String.t() => term()}
  @gib_bytes 1_073_741_824

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
      "tracker_project_slug" => get_string(display_config, ["tracker", "project_slug"]),
      "tracker_assignee" => get_string(display_config, ["tracker", "assignee"]),
      "active_states" => get_list_text(display_config, ["tracker", "active_states"]),
      "terminal_states" => get_list_text(display_config, ["tracker", "terminal_states"]),
      "polling_interval_ms" => get_integer_string(display_config, ["polling", "interval_ms"]),
      "project_repository_url" => get_string(display_config, ["project", "repository_url"]),
      "project_default_branch" => get_string(display_config, ["project", "default_branch"]),
      "project_checkout_depth" => get_integer_string(display_config, ["project", "checkout_depth"]),
      "project_source_strategy" => get_string(display_config, ["project", "source_strategy"]),
      "project_worktree_fetch" => get_boolean_string(display_config, ["project", "worktree_fetch"]),
      "project_worktree_cleanup" => get_boolean_string(display_config, ["project", "worktree_cleanup"]),
      "project_setup_commands" => get_list_text(display_config, ["project", "setup_commands"]),
      "project_cleanup_commands" => get_list_text(display_config, ["project", "cleanup_commands"]),
      "workspace_root" => get_string(display_config, ["workspace", "root"]),
      "workspace_repository_base_root" => get_string(display_config, ["workspace", "repository_base_root"]),
      "workspace_worktree_base_root" => get_string(display_config, ["workspace", "worktree_base_root"]),
      "initialize_timeout_ms" => get_integer_string(display_config, ["workspace", "initialize_timeout_ms"]),
      "workspace_min_free_gib" => min_free_gib_string(get_in(display_config, ["workspace", "min_free_bytes"])),
      "agent_max_concurrent_agents" => get_integer_string(display_config, ["agent", "max_concurrent_agents"]),
      "agent_max_turns" => get_integer_string(display_config, ["agent", "max_turns"]),
      "codex_command" => get_string(display_config, ["codex", "command"]),
      "codex_pre_start_commands" => get_list_text(display_config, ["codex", "pre_start_commands"]),
      "codex_approval_policy" => get_codex_approval_policy(display_config),
      "codex_thread_sandbox" => get_string(display_config, ["codex", "thread_sandbox"]),
      "codex_turn_sandbox_preset" => get_codex_turn_sandbox_preset(display_config),
      "codex_turn_sandbox_json" => get_codex_turn_sandbox_json(display_config),
      "codex_rate_limit_gate_enabled" => get_boolean_string(display_config, ["codex", "rate_limit_gate_enabled"]),
      "codex_rate_limit_gate_5h_threshold_percent" => get_number_string(display_config, ["codex", "rate_limit_gate_5h_threshold_percent"]),
      "codex_rate_limit_gate_7d_threshold_percent" => get_number_string(display_config, ["codex", "rate_limit_gate_7d_threshold_percent"]),
      "codex_rate_limit_gate_post_reset_delay_ms" => get_integer_string(display_config, ["codex", "rate_limit_gate_post_reset_delay_ms"]),
      "hook_after_create" => get_string(display_config, ["hooks", "after_create"]),
      "hook_before_run" => get_string(display_config, ["hooks", "before_run"]),
      "hook_after_run" => get_string(display_config, ["hooks", "after_run"]),
      "hook_before_remove" => get_string(display_config, ["hooks", "before_remove"]),
      "hook_timeout_ms" => get_integer_string(display_config, ["hooks", "timeout_ms"]),
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

  @spec field_errors(draft()) :: %{String.t() => String.t()}
  def field_errors(draft) when is_map(draft) do
    integer_field_specs()
    |> Enum.reduce(%{}, fn {key, label}, errors ->
      case parse_integer_field(draft, key, label) do
        {:ok, _value} -> errors
        {:error, message} -> Map.put(errors, key, message)
      end
    end)
    |> put_percent_error(draft, "codex_rate_limit_gate_5h_threshold_percent", "5-hour rate-limit threshold")
    |> put_percent_error(draft, "codex_rate_limit_gate_7d_threshold_percent", "7-day rate-limit threshold")
    |> put_turn_sandbox_error(draft)
  end

  @spec to_config(draft()) :: {:ok, map()} | {:error, String.t()}
  def to_config(draft) when is_map(draft) do
    with {:ok, polling_interval_ms} <- parse_positive_integer(draft, "polling_interval_ms", "Polling interval"),
         {:ok, checkout_depth} <- parse_positive_integer(draft, "project_checkout_depth", "Checkout depth"),
         {:ok, initialize_timeout_ms} <- parse_positive_integer(draft, "initialize_timeout_ms", "Initialize timeout"),
         {:ok, workspace_min_free_bytes} <- parse_min_free_bytes(draft),
         {:ok, max_agents} <- parse_positive_integer(draft, "agent_max_concurrent_agents", "Max agents"),
         {:ok, max_turns} <- parse_positive_integer(draft, "agent_max_turns", "Max turns"),
         {:ok, rate_limit_gate_5h_threshold} <- parse_percent(draft, "codex_rate_limit_gate_5h_threshold_percent", "5-hour rate-limit threshold"),
         {:ok, rate_limit_gate_7d_threshold} <- parse_percent(draft, "codex_rate_limit_gate_7d_threshold_percent", "7-day rate-limit threshold"),
         {:ok, rate_limit_gate_post_reset_delay_ms} <- parse_non_negative_integer(draft, "codex_rate_limit_gate_post_reset_delay_ms", "Rate-limit post-reset delay"),
         {:ok, hook_timeout_ms} <- parse_positive_integer(draft, "hook_timeout_ms", "Hook timeout"),
         {:ok, turn_sandbox_policy} <- turn_sandbox_policy_from_draft(draft) do
      config =
        draft
        |> Map.get("_base_config", %{})
        |> put_path(["tracker", "kind"], "linear")
        |> put_path(["tracker", "endpoint"], linear_endpoint(draft))
        |> put_optional_path(["tracker", "project_slug"], Map.get(draft, "tracker_project_slug", ""))
        |> put_optional_path(["tracker", "assignee"], Map.get(draft, "tracker_assignee", ""))
        |> put_path(["tracker", "active_states"], lines(Map.get(draft, "active_states", "")))
        |> put_path(["tracker", "terminal_states"], lines(Map.get(draft, "terminal_states", "")))
        |> put_path(["polling", "interval_ms"], polling_interval_ms)
        |> put_project(draft, checkout_depth)
        |> put_path(["workspace", "root"], Map.get(draft, "workspace_root", ""))
        |> put_optional_path(["workspace", "repository_base_root"], Map.get(draft, "workspace_repository_base_root", ""))
        |> put_optional_path(["workspace", "worktree_base_root"], Map.get(draft, "workspace_worktree_base_root", ""))
        |> put_path(["workspace", "initialize_timeout_ms"], initialize_timeout_ms)
        |> put_path(["workspace", "min_free_bytes"], workspace_min_free_bytes)
        |> put_path(["agent", "max_concurrent_agents"], max_agents)
        |> put_path(["agent", "max_turns"], max_turns)
        |> put_path(["codex", "command"], Map.get(draft, "codex_command", ""))
        |> put_path(["codex", "pre_start_commands"], lines(Map.get(draft, "codex_pre_start_commands", "")))
        |> put_path(["codex", "approval_policy"], Map.get(draft, "codex_approval_policy", "never"))
        |> put_path(["codex", "thread_sandbox"], Map.get(draft, "codex_thread_sandbox", ""))
        |> put_path(["codex", "turn_sandbox_policy"], turn_sandbox_policy)
        |> put_path(["codex", "rate_limit_gate_enabled"], truthy?(Map.get(draft, "codex_rate_limit_gate_enabled", "true")))
        |> put_path(["codex", "rate_limit_gate_5h_threshold_percent"], rate_limit_gate_5h_threshold)
        |> put_path(["codex", "rate_limit_gate_7d_threshold_percent"], rate_limit_gate_7d_threshold)
        |> put_path(["codex", "rate_limit_gate_post_reset_delay_ms"], rate_limit_gate_post_reset_delay_ms)
        |> put_path(["hooks"], hooks_config(draft, hook_timeout_ms))
        |> put_path(["profiles"], profiles_config(draft))
        |> put_path(["workflow"], Schema.default_workflow_policy())

      {:ok, config}
    end
  end

  defp integer_field_specs do
    [
      {"polling_interval_ms", "Polling interval"},
      {"initialize_timeout_ms", "Initialize timeout"},
      {"workspace_min_free_gib", "Minimum free GiB"},
      {"agent_max_concurrent_agents", "Max agents"},
      {"agent_max_turns", "Max turns"},
      {"codex_rate_limit_gate_post_reset_delay_ms", "Rate-limit post-reset delay"},
      {"hook_timeout_ms", "Hook timeout"}
    ]
  end

  defp get_codex_approval_policy(config) do
    config
    |> get_in(["codex", "approval_policy"])
    |> Schema.normalize_codex_approval_policy()
  end

  defp get_codex_turn_sandbox_preset(config) do
    config
    |> get_in(["codex", "turn_sandbox_policy"])
    |> codex_turn_sandbox_preset()
  end

  defp get_codex_turn_sandbox_json(config) do
    case get_in(config, ["codex", "turn_sandbox_policy"]) do
      policy when is_map(policy) -> Jason.encode!(policy, pretty: true)
      _ -> ""
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

  defp hooks_config(draft, timeout_ms) do
    %{"timeout_ms" => timeout_ms}
    |> put_optional_path(["after_create"], Map.get(draft, "hook_after_create", ""))
    |> put_optional_path(["before_run"], Map.get(draft, "hook_before_run", ""))
    |> put_optional_path(["after_run"], Map.get(draft, "hook_after_run", ""))
    |> put_optional_path(["before_remove"], Map.get(draft, "hook_before_remove", ""))
  end

  defp put_turn_sandbox_error(errors, draft) do
    case turn_sandbox_policy_from_draft(draft) do
      {:ok, _policy} -> errors
      {:error, message} -> Map.put(errors, "codex_turn_sandbox_json", message)
    end
  end

  defp turn_sandbox_policy_from_draft(draft) do
    case Map.get(draft, "codex_turn_sandbox_preset", "workspace_write_no_network") do
      "workspace_write_network" ->
        {:ok, workspace_write_policy(true)}

      "danger_full_access" ->
        {:ok, %{"type" => "dangerFullAccess"}}

      "custom" ->
        decode_custom_turn_sandbox_policy(Map.get(draft, "codex_turn_sandbox_json", ""))

      _ ->
        {:ok, workspace_write_policy(false)}
    end
  end

  defp workspace_write_policy(network_access) do
    %{
      "type" => "workspaceWrite",
      "networkAccess" => network_access,
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp decode_custom_turn_sandbox_policy(value) do
    case Jason.decode(to_string(value || "")) do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      {:ok, _value} -> {:error, "Turn sandbox custom JSON must decode to an object"}
      {:error, _error} -> {:error, "Turn sandbox custom JSON is invalid"}
    end
  end

  defp codex_turn_sandbox_preset(%{"type" => "dangerFullAccess"}), do: "danger_full_access"

  defp codex_turn_sandbox_preset(%{"type" => "workspaceWrite", "networkAccess" => true}),
    do: "workspace_write_network"

  defp codex_turn_sandbox_preset(%{"type" => "workspaceWrite"}), do: "workspace_write_no_network"
  defp codex_turn_sandbox_preset(policy) when is_map(policy), do: "custom"
  defp codex_turn_sandbox_preset(_policy), do: "workspace_write_no_network"

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

  defp put_project(config, draft, checkout_depth) do
    config
    |> put_optional_path(["project", "repository_url"], Map.get(draft, "project_repository_url", ""))
    |> put_optional_path(["project", "default_branch"], Map.get(draft, "project_default_branch", ""))
    |> put_path(["project", "checkout_depth"], checkout_depth)
    |> put_path(["project", "source_strategy"], Map.get(draft, "project_source_strategy", "clone"))
    |> put_path(["project", "worktree_fetch"], truthy?(Map.get(draft, "project_worktree_fetch", "true")))
    |> put_path(["project", "worktree_cleanup"], truthy?(Map.get(draft, "project_worktree_cleanup", "true")))
    |> put_path(["project", "setup_commands"], lines(Map.get(draft, "project_setup_commands", "")))
    |> put_path(["project", "cleanup_commands"], lines(Map.get(draft, "project_cleanup_commands", "")))
  end

  defp normalized_display_config(config) do
    case Schema.parse(config) do
      {:ok, settings} ->
        deep_merge(config, Schema.to_external_config(settings))

      {:error, _reason} ->
        deep_merge(Schema.defaults(), config)
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp parse_positive_integer(draft, key, label) do
    value = Map.get(draft, key, "")

    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, "#{label} must be a positive integer"}
    end
  end

  defp parse_non_negative_integer(draft, key, label) do
    value = Map.get(draft, key, default_number_field_value(key, "1073741824"))

    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, "#{label} must be zero or a positive integer"}
    end
  end

  defp parse_integer_field(draft, "workspace_min_free_gib", _label), do: parse_min_free_bytes(draft)

  defp parse_integer_field(draft, "codex_rate_limit_gate_post_reset_delay_ms", label),
    do: parse_non_negative_integer(draft, "codex_rate_limit_gate_post_reset_delay_ms", label)

  defp parse_integer_field(draft, key, label), do: parse_positive_integer(draft, key, label)

  defp parse_percent(draft, key, label) do
    value =
      draft
      |> Map.get(key, default_number_field_value(key, ""))
      |> to_string()
      |> String.trim()

    case Float.parse(value) do
      {number, ""} when number >= 0 and number <= 100 -> {:ok, number}
      _ -> {:error, "#{label} must be between 0 and 100"}
    end
  end

  defp default_number_field_value("codex_rate_limit_gate_5h_threshold_percent", _fallback), do: "5"
  defp default_number_field_value("codex_rate_limit_gate_7d_threshold_percent", _fallback), do: "3"
  defp default_number_field_value("codex_rate_limit_gate_post_reset_delay_ms", _fallback), do: "1200000"
  defp default_number_field_value(_key, fallback), do: fallback

  defp put_percent_error(errors, draft, key, label) do
    case parse_percent(draft, key, label) do
      {:ok, _value} -> errors
      {:error, message} -> Map.put(errors, key, message)
    end
  end

  defp parse_min_free_bytes(%{"workspace_min_free_bytes" => value} = draft)
       when not is_map_key(draft, "workspace_min_free_gib") do
    parse_non_negative_integer(%{"workspace_min_free_bytes" => value}, "workspace_min_free_bytes", "Minimum free bytes")
  end

  defp parse_min_free_bytes(draft) do
    value =
      draft
      |> Map.get("workspace_min_free_gib", "1")
      |> to_string()
      |> String.trim()

    case Decimal.parse(value) do
      {decimal, ""} ->
        if Decimal.compare(decimal, Decimal.new(0)) in [:eq, :gt] do
          bytes =
            decimal
            |> Decimal.mult(Decimal.new(@gib_bytes))
            |> Decimal.round(0, :half_up)
            |> Decimal.to_integer()

          {:ok, bytes}
        else
          {:error, "Minimum free GiB must be zero or a positive number"}
        end

      _ ->
        {:error, "Minimum free GiB must be zero or a positive number"}
    end
  end

  defp get_string(config, path), do: get_string(config, path, "")

  defp get_string(config, path, default) do
    case get_in(config, path) do
      value when is_binary(value) -> value
      nil -> default
      value -> to_string(value)
    end
  end

  defp get_integer_string(config, path) do
    case get_in(config, path) do
      value when is_integer(value) -> Integer.to_string(value)
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp get_number_string(config, path) do
    case get_in(config, path) do
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> value |> Float.to_string() |> trim_trailing_decimal()
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp trim_trailing_decimal(value) when is_binary(value) do
    value
    |> String.replace(~r/\.0$/, "")
  end

  defp min_free_gib_string(value) do
    bytes =
      case value do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {integer, ""} -> integer
            _ -> @gib_bytes
          end

        _ ->
          @gib_bytes
      end

    bytes
    |> Decimal.new()
    |> Decimal.div(Decimal.new(@gib_bytes))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp get_boolean_string(config, path) do
    case get_in(config, path) do
      value when is_boolean(value) -> to_string(value)
      value when is_binary(value) -> value
      _ -> ""
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

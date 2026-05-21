defmodule SymphonyElixir.Config.WorkflowContract do
  @moduledoc """
  Pure workflow/profile contract validation for runtime settings.
  """

  alias SymphonyElixir.Config.Schema

  @linear_state_name_max_length 25

  @spec workflow_errors(map(), map(), term()) :: [String.t()]
  def workflow_errors(workflow, profiles, tracker) when is_map(workflow) do
    workflow = normalize_keys(workflow)
    profiles = normalize_keys(profiles || %{})

    []
    |> Kernel.++(validate_no_nested_profiles(workflow))
    |> Kernel.++(validate_tracker_state_names(tracker))
    |> Kernel.++(validate_states(Map.get(workflow, "states", %{}), profiles))
    |> Kernel.++(validate_string_list(Map.get(workflow, "human_review_states", []), "human_review_states"))
    |> Kernel.++(validate_transitions(Map.get(workflow, "allowed_transitions", [])))
    |> Kernel.++(validate_workflow_state_references(workflow, profiles, tracker))
  end

  def workflow_errors(_workflow, _profiles, _tracker), do: ["must be a map"]

  @spec profile_errors(map()) :: [String.t()]
  def profile_errors(profiles) when is_map(profiles) do
    profiles
    |> normalize_keys()
    |> Enum.flat_map(fn {profile, policy} ->
      cond do
        not is_binary(profile) or String.trim(profile) == "" ->
          ["profiles must use non-empty string names"]

        not is_map(policy) ->
          ["profiles.#{profile} must be a map"]

        Map.has_key?(policy, "active_states") ->
          ["profiles.#{profile}.active_states is not supported; use workflow.states"]

        true ->
          validate_profile_name(profile, Map.get(policy, "name")) ++
            validate_executor(profile, Map.get(policy, "executor")) ++
            validate_prompt_policy(profile, Map.get(policy, "prompt")) ++
            validate_profile_executor_prompt(profile, policy) ++
            validate_allowed_updates(profile, Map.get(policy, "allowed_updates", %{}))
      end
    end)
  end

  def profile_errors(_profiles), do: ["profiles must be a map"]

  @spec known_states(map(), term()) :: MapSet.t()
  def known_states(workflow, tracker) do
    workflow = normalize_keys(workflow || %{})

    []
    |> Kernel.++(tracker_states(tracker, :active_states))
    |> Kernel.++(tracker_states(tracker, :terminal_states))
    |> Kernel.++(Map.keys(Map.get(workflow, "states", %{})))
    |> Kernel.++(Map.get(workflow, "human_review_states", []))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new(&Schema.normalize_issue_state/1)
  end

  defp validate_no_nested_profiles(workflow) do
    if Map.has_key?(workflow, "profiles") do
      ["workflow.profiles is not supported; define profiles at top-level profiles"]
    else
      []
    end
  end

  defp validate_states(states, profiles) when is_map(states) do
    known_profiles =
      Schema.default_profiles()
      |> Map.merge(profiles)
      |> Map.keys()
      |> MapSet.new()

    Enum.flat_map(states, &validate_state_policy(&1, known_profiles))
  end

  defp validate_states(_states, _profiles), do: ["states must be a map"]

  defp validate_state_policy({state, policy}, known_profiles) when is_binary(state) do
    if String.trim(state) == "" do
      ["states must use non-empty state names"]
    else
      validate_named_state_policy(state, policy, known_profiles)
    end
  end

  defp validate_state_policy(_entry, _known_profiles), do: ["states must use non-empty state names"]

  defp validate_named_state_policy(state, policy, known_profiles) do
    if linear_state_name_too_long?(state) do
      [linear_state_name_length_error("states.#{state}", state)]
    else
      validate_state_policy_map(state, policy, known_profiles)
    end
  end

  defp validate_state_policy_map(state, policy, known_profiles) when is_map(policy) do
    validate_state_policy_profile(state, Map.get(policy, "profile"), known_profiles)
  end

  defp validate_state_policy_map(state, _policy, _known_profiles), do: ["states.#{state} must be a map"]

  defp validate_state_policy_profile(state, profile, known_profiles) do
    cond do
      not is_binary(profile) or String.trim(profile) == "" ->
        ["states.#{state}.profile must be a non-empty string"]

      not MapSet.member?(known_profiles, profile) ->
        ["states.#{state}.profile references unknown profile #{profile}"]

      true ->
        []
    end
  end

  defp validate_profile_name(profile, name) do
    if is_binary(name) and String.trim(name) != "" do
      []
    else
      ["profiles.#{profile}.name must be a non-empty string"]
    end
  end

  defp validate_executor(_profile, %{"type" => type}) when type in ["codex_agent", "manual", "backend_action", "external_worker"] do
    []
  end

  defp validate_executor(profile, %{"type" => _type}), do: ["profiles.#{profile}.executor.type is invalid"]
  defp validate_executor(profile, _executor), do: ["profiles.#{profile}.executor.type must be a non-empty string"]

  defp validate_prompt_policy(_profile, %{"mode" => mode}) when mode in ["extend", "replace", "disabled"], do: []
  defp validate_prompt_policy(profile, %{"mode" => _mode}), do: ["profiles.#{profile}.prompt.mode is invalid"]
  defp validate_prompt_policy(profile, _prompt), do: ["profiles.#{profile}.prompt.mode must be a non-empty string"]

  defp validate_profile_executor_prompt(profile, policy) do
    executor_type = get_in(policy, ["executor", "type"])
    prompt_mode = get_in(policy, ["prompt", "mode"])
    prompt_template = get_in(policy, ["prompt", "template"])

    cond do
      executor_type == "codex_agent" and prompt_mode == "disabled" ->
        ["profiles.#{profile}.prompt.mode cannot be disabled for codex_agent"]

      executor_type == "codex_agent" and prompt_mode in ["extend", "replace"] and not non_empty_string?(prompt_template) ->
        ["profiles.#{profile}.prompt.template must be a non-empty string for codex_agent #{prompt_mode} mode"]

      true ->
        []
    end
  end

  defp validate_allowed_updates(profile, updates) when is_map(updates) do
    validate_string_list(Map.get(updates, "target_states", []), "profiles.#{profile}.allowed_updates.target_states")
  end

  defp validate_allowed_updates(profile, _updates), do: ["profiles.#{profile}.allowed_updates must be a map"]

  defp validate_transitions(transitions) when is_list(transitions) do
    Enum.flat_map(transitions, fn
      transition when is_map(transition) ->
        from = Map.get(transition, "from")
        to = Map.get(transition, "to")
        actor = Map.get(transition, "actor")

        []
        |> maybe_required_string_error(from, "allowed_transitions.from")
        |> maybe_required_string_error(to, "allowed_transitions.to")
        |> maybe_linear_state_name_length_error(from, "allowed_transitions.from")
        |> maybe_linear_state_name_length_error(to, "allowed_transitions.to")
        |> maybe_actor_error(actor)

      _transition ->
        ["allowed_transitions entries must be maps"]
    end)
  end

  defp validate_transitions(_transitions), do: ["allowed_transitions must be a list"]

  defp validate_workflow_state_references(workflow, profiles, tracker) do
    used_profiles = workflow_used_profiles(workflow)

    profiles =
      Schema.default_profiles()
      |> Map.take(used_profiles)
      |> Map.merge(profiles, fn _profile, default_profile, configured_profile ->
        Map.merge(default_profile, configured_profile)
      end)

    known_states = known_states(workflow, tracker)

    validate_transition_state_references(Map.get(workflow, "allowed_transitions", []), known_states) ++
      validate_profile_target_state_references(profiles, known_states)
  end

  defp workflow_used_profiles(workflow) do
    state_profiles =
      workflow
      |> Map.get("states", %{})
      |> Enum.map(fn {_state, policy} -> if is_map(policy), do: Map.get(policy, "profile") end)

    transition_profiles =
      workflow
      |> Map.get("allowed_transitions", [])
      |> Enum.map(fn transition -> if is_map(transition), do: Map.get(transition, "profile") end)

    state_profiles
    |> Kernel.++(transition_profiles)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp tracker_states(%Schema.Tracker{} = tracker, field), do: Map.get(tracker, field) || []
  defp tracker_states(_tracker, _field), do: []

  defp validate_tracker_state_names(%Schema.Tracker{} = tracker) do
    validate_string_list(tracker.active_states || [], "tracker.active_states") ++
      validate_string_list(tracker.terminal_states || [], "tracker.terminal_states")
  end

  defp validate_tracker_state_names(_tracker), do: []

  defp validate_transition_state_references(transitions, known_states) when is_list(transitions) do
    Enum.flat_map(transitions, fn
      transition when is_map(transition) ->
        Enum.flat_map(["from", "to"], &transition_state_reference_errors(transition, known_states, &1))

      _transition ->
        []
    end)
  end

  defp validate_transition_state_references(_transitions, _known_states), do: []

  defp transition_state_reference_errors(transition, known_states, field) do
    state = Map.get(transition, field)

    if known_state?(known_states, state) do
      []
    else
      ["allowed_transitions.#{field} references unknown workflow state #{inspect(state)}"]
    end
  end

  defp validate_profile_target_state_references(profiles, known_states) when is_map(profiles) do
    Enum.flat_map(profiles, fn {profile, policy} ->
      policy
      |> get_in(["allowed_updates", "target_states"])
      |> case do
        states when is_list(states) ->
          states
          |> Enum.reject(&known_state?(known_states, &1))
          |> Enum.map(&"profiles.#{profile}.allowed_updates.target_states references unknown workflow state #{inspect(&1)}")

        _states ->
          []
      end
    end)
  end

  defp known_state?(known_states, state) when is_binary(state) do
    MapSet.member?(known_states, Schema.normalize_issue_state(String.trim(state)))
  end

  defp known_state?(_known_states, _state), do: true

  defp maybe_required_string_error(errors, value, field) do
    if is_binary(value) and String.trim(value) != "", do: errors, else: [field <> " must be a non-empty string" | errors]
  end

  defp maybe_linear_state_name_length_error(errors, value, field) do
    if linear_state_name_too_long?(value), do: [linear_state_name_length_error(field, value) | errors], else: errors
  end

  defp maybe_actor_error(errors, actor) do
    if actor in ["codex", "human"], do: errors, else: ["allowed_transitions.actor must be either codex or human" | errors]
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_string_list(values, field) when is_list(values) do
    cond do
      not Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) ->
        [field <> " must be a list of non-empty strings"]

      too_long = Enum.find(values, &linear_state_name_too_long?/1) ->
        [linear_state_name_length_error(field, too_long)]

      true ->
        []
    end
  end

  defp validate_string_list(_values, field), do: [field <> " must be a list of non-empty strings"]

  defp linear_state_name_too_long?(value) when is_binary(value) do
    value |> String.trim() |> String.length() > @linear_state_name_max_length
  end

  defp linear_state_name_too_long?(_value), do: false

  defp linear_state_name_length_error(field, value) do
    "#{field} exceeds Linear state name limit of #{@linear_state_name_max_length} characters: #{inspect(value)}"
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end

defmodule SymphonyElixir.Linear.WorkflowStateValidator do
  @moduledoc """
  Compares Symphony workflow state references with Linear team workflow states.
  """

  @type result :: %{
          status: :ok | :error,
          available: [String.t()],
          missing: map(),
          required_states: [String.t()],
          missing_states: [String.t()]
        }

  @spec validate(map(), [String.t()]) :: result()
  def validate(settings, available_state_names) when is_map(settings) and is_list(available_state_names) do
    available = state_name_set(available_state_names)
    workflow = Map.get(settings, :workflow, %{}) || %{}
    profiles = Map.get(settings, :profiles, %{}) || %{}
    tracker = Map.get(settings, :tracker, %{}) || %{}

    missing = %{
      active_states: missing_states(Map.get(tracker, :active_states, []), available),
      terminal_states: missing_states(Map.get(tracker, :terminal_states, []), available),
      human_review_states: missing_states(Map.get(workflow, "human_review_states", []), available),
      transitions: missing_transition_states(Map.get(workflow, "allowed_transitions", []), available),
      profile_target_states: missing_profile_target_states(profiles, available),
      state_routes: missing_state_routes(Map.get(workflow, "states", %{}), available)
    }

    missing_states =
      missing
      |> flatten_missing_states()
      |> Enum.uniq()
      |> Enum.sort()

    %{
      status: if(missing_states == [], do: :ok, else: :error),
      available: Enum.sort(available_state_names),
      required_states: required_states(settings),
      missing_states: missing_states,
      missing: missing
    }
  end

  def validate(_settings, available_state_names), do: validate(%{}, available_state_names)

  @spec required_states(map()) :: [String.t()]
  def required_states(settings) when is_map(settings) do
    workflow = Map.get(settings, :workflow, %{}) || %{}
    profiles = Map.get(settings, :profiles, %{}) || %{}
    tracker = Map.get(settings, :tracker, %{}) || %{}

    [
      Map.get(tracker, :active_states, []),
      Map.get(tracker, :terminal_states, []),
      Map.get(workflow, "human_review_states", []),
      Map.keys(Map.get(workflow, "states", %{}) || %{}),
      transition_state_names(Map.get(workflow, "allowed_transitions", [])),
      profile_target_state_names(profiles)
    ]
    |> List.flatten()
    |> normalize_configured_list()
  end

  def required_states(_settings), do: []

  defp missing_states(configured, available) do
    configured
    |> normalize_configured_list()
    |> Enum.reject(fn state -> MapSet.member?(available, normalize_state_name(state)) end)
  end

  defp missing_transition_states(transitions, available) when is_list(transitions) do
    transitions
    |> Enum.flat_map(fn
      %{"from" => from, "to" => to} = transition ->
        missing = missing_states([from, to], available)

        if missing == [] do
          []
        else
          [%{from: from, to: to, actor: Map.get(transition, "actor"), profile: Map.get(transition, "profile"), missing: missing}]
        end

      _ ->
        []
    end)
  end

  defp missing_transition_states(_transitions, _available), do: []

  defp missing_profile_target_states(profiles, available) when is_map(profiles) do
    profiles
    |> Enum.flat_map(fn {profile_id, profile} ->
      states = get_in(profile, ["allowed_updates", "target_states"]) || []
      missing = missing_states(states, available)

      if missing == [], do: [], else: [%{profile: profile_id, states: missing}]
    end)
    |> Enum.sort_by(& &1.profile)
  end

  defp missing_profile_target_states(_profiles, _available), do: []

  defp missing_state_routes(states, available) when is_map(states) do
    states
    |> Map.keys()
    |> missing_states(available)
  end

  defp missing_state_routes(_states, _available), do: []

  defp transition_state_names(transitions) when is_list(transitions) do
    Enum.flat_map(transitions, fn
      %{"from" => from, "to" => to} -> [from, to]
      _ -> []
    end)
  end

  defp transition_state_names(_transitions), do: []

  defp profile_target_state_names(profiles) when is_map(profiles) do
    Enum.flat_map(profiles, fn {_profile_id, profile} ->
      get_in(profile, ["allowed_updates", "target_states"]) || []
    end)
  end

  defp profile_target_state_names(_profiles), do: []

  defp flatten_missing_states(missing) when is_map(missing) do
    direct =
      missing
      |> Map.take([:active_states, :terminal_states, :human_review_states, :state_routes])
      |> Map.values()
      |> List.flatten()

    transition_states =
      missing
      |> Map.get(:transitions, [])
      |> Enum.flat_map(&Map.get(&1, :missing, []))

    profile_states =
      missing
      |> Map.get(:profile_target_states, [])
      |> Enum.flat_map(&Map.get(&1, :states, []))

    direct ++ transition_states ++ profile_states
  end

  defp normalize_configured_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_configured_list(_values), do: []

  defp state_name_set(names) when is_list(names) do
    names
    |> Enum.map(&normalize_state_name/1)
    |> MapSet.new()
  end

  defp normalize_state_name(state), do: state |> to_string() |> String.trim() |> String.downcase()
end

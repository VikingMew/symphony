defmodule SymphonyElixir.Linear.StateFixes do
  @moduledoc """
  Builds operator-facing guidance for Linear workflow state mismatches.
  """

  @type fix_item :: %{
          state: String.t(),
          references: String.t(),
          action: String.t()
        }

  @spec items(map()) :: [fix_item()]
  def items(%{missing_states: states, missing: missing, available: available}) when is_list(states) do
    Enum.map(states, fn state ->
      %{
        state: state,
        references: state_reference_text(state, missing),
        action: state_action_text(state, available)
      }
    end)
  end

  def items(_check), do: []

  defp state_reference_text(state, missing) do
    refs =
      []
      |> add_state_ref(state, missing[:active_states], "Active states")
      |> add_state_ref(state, missing[:terminal_states], "Terminal states")
      |> add_state_ref(state, missing[:human_review_states], "Human review states")
      |> add_state_ref(state, missing[:state_routes], "Workflow state routing")
      |> Kernel.++(transition_refs(state, missing[:transitions]))
      |> Kernel.++(profile_refs(state, missing[:profile_target_states]))

    "Referenced by #{Enum.join(Enum.uniq(refs), ", ")}"
  end

  defp add_state_ref(refs, state, states, label) when is_list(states) do
    if state in states, do: refs ++ [label], else: refs
  end

  defp add_state_ref(refs, _state, _states, _label), do: refs

  defp transition_refs(state, transitions) when is_list(transitions) do
    transitions
    |> Enum.filter(&(state in Map.get(&1, :missing, [])))
    |> Enum.map(fn transition ->
      "Allowed transition #{Map.get(transition, :from)} -> #{Map.get(transition, :to)}"
    end)
  end

  defp transition_refs(_state, _transitions), do: []

  defp profile_refs(state, profiles) when is_list(profiles) do
    profiles
    |> Enum.filter(&(state in Map.get(&1, :states, [])))
    |> Enum.map(&"Profile #{Map.get(&1, :profile)} target states")
  end

  defp profile_refs(_state, _profiles), do: []

  defp state_action_text(state, available) do
    case similar_state_names(state, available) do
      [] -> "Create this status in Linear, or remove/rename this reference in Settings / Workflow."
      suggestions -> "Rename it to one of the existing Linear states if appropriate: #{Enum.join(suggestions, ", ")}. Otherwise create this status in Linear."
    end
  end

  defp similar_state_names(state, available) do
    state_tokens = state_tokens(state)

    available
    |> Enum.filter(fn candidate ->
      overlap = MapSet.intersection(state_tokens, state_tokens(candidate)) |> MapSet.size()
      overlap > 0 or spelling_pair?(state, candidate)
    end)
    |> Enum.take(4)
  end

  defp state_tokens(state) do
    state
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in ["to", "in", "the"]))
    |> MapSet.new()
  end

  defp spelling_pair?(left, right) do
    normalized_left = left |> to_string() |> String.downcase()
    normalized_right = right |> to_string() |> String.downcase()

    {normalized_left, normalized_right} in [{"cancelled", "canceled"}, {"canceled", "cancelled"}]
  end
end

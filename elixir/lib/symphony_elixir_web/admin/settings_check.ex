defmodule SymphonyElixirWeb.Admin.SettingsCheck do
  @moduledoc """
  Settings validation target and field-highlighting presentation policy.
  """

  @spec workflow_check_targets(map(), term()) :: [map()]
  def workflow_check_targets(draft, message) do
    text = to_string(message)
    quoted = quoted_values(text)

    []
    |> Kernel.++(workflow_state_length_targets(text))
    |> Kernel.++(workflow_tracker_targets(text))
    |> Kernel.++(workflow_human_review_targets(text))
    |> Kernel.++(workflow_state_route_targets(text, draft))
    |> Kernel.++(workflow_transition_targets(text, draft, quoted))
    |> Kernel.++(workflow_profile_targets(text, quoted))
    |> Enum.uniq_by(fn target -> {target.tab, target.field, target.scope, target.message} end)
  end

  @spec class([map()], atom(), atom(), term(), String.t()) :: [String.t() | nil]
  def class(targets, tab, field, scope \\ nil, base \\ "settings-field") do
    [base, if(invalid?(targets, tab, field, scope), do: "settings-check-invalid")]
  end

  @spec title_class([map()], atom(), atom(), term(), String.t()) :: [String.t() | nil]
  def title_class(targets, tab, field, scope \\ nil, base \\ "metric-label") do
    [base, if(invalid?(targets, tab, field, scope), do: "settings-check-title-invalid")]
  end

  @spec invalid?([map()], atom(), atom(), term()) :: boolean()
  def invalid?(targets, tab, field, scope \\ nil) do
    Enum.any?(targets, &match_target?(&1, tab, field, scope))
  end

  @spec messages([map()], atom(), atom(), term()) :: [String.t()]
  def messages(targets, tab, field, scope) do
    targets
    |> Enum.filter(&match_target?(&1, tab, field, scope))
    |> Enum.map(& &1.message)
    |> Enum.uniq()
  end

  @spec project_field_class([map()], String.t()) :: [String.t() | nil]
  def project_field_class(items, title) do
    ["settings-field", if(project_item_present?(items, title), do: "settings-check-invalid")]
  end

  @spec project_field_title_class([map()], String.t()) :: [String.t() | nil]
  def project_field_title_class(items, title) do
    ["metric-label", if(project_item_present?(items, title), do: "settings-check-title-invalid")]
  end

  defp workflow_state_length_targets(text) do
    cond do
      String.contains?(text, "tracker.active_states") ->
        [check_target(:workflow, :active_states, nil, "Active states", text)]

      String.contains?(text, "tracker.terminal_states") ->
        [check_target(:workflow, :terminal_states, nil, "Terminal states", text)]

      String.contains?(text, "human_review_states") ->
        [check_target(:workflow, :human_review_states, nil, "Human review states", text)]

      true ->
        []
    end
  end

  defp workflow_tracker_targets(text) do
    []
    |> maybe_check_target(String.contains?(text, "tracker.active_states"), :workflow, :active_states, nil, "Active states", text)
    |> maybe_check_target(String.contains?(text, "tracker.terminal_states"), :workflow, :terminal_states, nil, "Terminal states", text)
  end

  defp workflow_human_review_targets(text) do
    if String.contains?(text, "human_review_states") do
      [check_target(:workflow, :human_review_states, nil, "Human review states", text)]
    else
      []
    end
  end

  defp workflow_state_route_targets(text, draft) do
    states = draft |> Map.get("workflow_states", %{}) |> Map.keys()

    states
    |> Enum.filter(&(String.contains?(text, "states.#{&1}") or String.contains?(text, inspect(&1))))
    |> Enum.map(&check_target(:workflow, :workflow_state, &1, "Workflow state #{&1}", text))
  end

  defp workflow_transition_targets(text, draft, quoted) do
    if String.contains?(text, "allowed_transitions") do
      draft
      |> transition_entries()
      |> Enum.filter(fn {transition, _index} -> transition_matches_message?(transition, quoted, text) end)
      |> transition_check_targets(text)
    else
      []
    end
  end

  defp transition_check_targets([], text), do: [check_target(:workflow, :allowed_transitions, nil, "Allowed transitions", text)]

  defp transition_check_targets(entries, text) do
    Enum.map(entries, fn {_transition, index} ->
      check_target(:workflow, :allowed_transition, index, "Allowed transition #{index + 1}", text)
    end)
  end

  defp workflow_profile_targets(text, quoted) do
    Regex.scan(~r/profiles\.([^. ,]+)\.([^,\n]+)/, text)
    |> Enum.flat_map(fn [_match, profile, rest] ->
      field =
        cond do
          String.contains?(rest, "allowed_updates.target_states") -> :profile_target_states
          String.contains?(rest, "prompt.template") -> :profile_prompt_template
          String.contains?(rest, "prompt.mode") -> :profile_prompt_mode
          String.contains?(rest, "executor.type") -> :profile_executor
          String.starts_with?(rest, "name") -> :profile_name
          true -> :profile_panel
        end

      title = profile_target_title(field, profile)
      message = profile_message(text, quoted)

      [
        check_target(:agents, field, profile, title, message),
        check_target(:agents, :profile_panel, profile, "Profile #{profile}", message)
      ]
    end)
  end

  defp profile_message(text, []), do: text
  defp profile_message(text, quoted), do: "#{text} (#{Enum.join(quoted, ", ")})"

  defp profile_target_title(:profile_target_states, profile), do: "#{profile} allowed target states"
  defp profile_target_title(:profile_prompt_template, profile), do: "#{profile} prompt template"
  defp profile_target_title(:profile_prompt_mode, profile), do: "#{profile} prompt mode"
  defp profile_target_title(:profile_executor, profile), do: "#{profile} executor"
  defp profile_target_title(:profile_name, profile), do: "#{profile} name"
  defp profile_target_title(_field, profile), do: "Profile #{profile}"

  defp quoted_values(text) do
    Regex.scan(~r/"([^"]+)"/, text)
    |> Enum.map(fn [_match, value] -> value end)
  end

  defp transition_matches_message?(_transition, [], _text), do: true

  defp transition_matches_message?(transition, quoted, text) do
    values = [Map.get(transition, "from"), Map.get(transition, "to"), Map.get(transition, "actor"), Map.get(transition, "profile")]

    Enum.any?(values, fn value ->
      value = to_string(value || "")
      value != "" and (Enum.member?(quoted, value) or String.contains?(text, value))
    end)
  end

  defp transition_entries(form) do
    form
    |> Map.get("allowed_transitions", [])
    |> normalize_transition_entries()
    |> Enum.with_index()
  end

  defp normalize_transition_entries(entries) when is_list(entries), do: entries

  defp normalize_transition_entries(entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {index, _entry} ->
      case Integer.parse(to_string(index)) do
        {integer, ""} -> integer
        _ -> 0
      end
    end)
    |> Enum.map(fn {_index, entry} -> entry end)
  end

  defp normalize_transition_entries(_entries), do: []

  defp maybe_check_target(targets, true, tab, field, scope, title, message), do: [check_target(tab, field, scope, title, message) | targets]
  defp maybe_check_target(targets, false, _tab, _field, _scope, _title, _message), do: targets

  defp check_target(tab, field, scope, title, message) do
    %{tab: tab, field: field, scope: scope, title: title, message: message}
  end

  defp match_target?(target, tab, field, scope) do
    target.tab == tab and target.field == field and normalize_scope(target.scope) == normalize_scope(scope)
  end

  defp normalize_scope(nil), do: nil
  defp normalize_scope(scope), do: to_string(scope)

  defp project_item_present?(items, title), do: Enum.any?(items, &(Map.get(&1, :title) == title))
end

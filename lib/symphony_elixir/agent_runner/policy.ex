defmodule SymphonyElixir.AgentRunner.Policy do
  @moduledoc """
  Pure policy helpers used by `AgentRunner`.
  """

  alias SymphonyElixir.Linear.Issue

  @implementation_profile "implementation"
  @implementation_start_state "Ready"
  @implementation_started_state "In Progress"
  @refinement_profile "refinement"
  @refinement_start_state "Todo"
  @refinement_started_state "Refining"

  @spec implementation_start_transition_required?(Issue.t() | term(), String.t() | nil) :: boolean()
  def implementation_start_transition_required?(%Issue{state: state}, @implementation_profile) do
    normalize_issue_state(state) == normalize_issue_state(@implementation_start_state)
  end

  def implementation_start_transition_required?(_issue, _profile), do: false

  @spec refinement_start_transition_required?(Issue.t() | term(), String.t() | nil) :: boolean()
  def refinement_start_transition_required?(%Issue{state: state}, @refinement_profile) do
    normalize_issue_state(state) == normalize_issue_state(@refinement_start_state)
  end

  def refinement_start_transition_required?(_issue, _profile), do: false

  @spec workflow_transition_allowed?([map()], String.t(), String.t(), String.t() | nil) :: boolean()
  def workflow_transition_allowed?(transitions, from_state, to_state, profile) when is_list(transitions) do
    Enum.any?(transitions, &matching_transition?(&1, from_state, to_state, profile))
  end

  def workflow_transition_allowed?(_transitions, _from_state, _to_state, _profile), do: false

  @spec validate_implementation_start_transition([map()], String.t(), String.t() | nil) :: :ok | {:error, term()}
  def validate_implementation_start_transition(transitions, from_state, profile) do
    if workflow_transition_allowed?(transitions, from_state, @implementation_started_state, profile) do
      :ok
    else
      {:error, {:transition_not_allowed, from_state, @implementation_started_state, profile}}
    end
  end

  @spec validate_refinement_start_transition([map()], String.t(), String.t() | nil) :: :ok | {:error, term()}
  def validate_refinement_start_transition(transitions, from_state, profile) do
    if workflow_transition_allowed?(
         transitions,
         from_state,
         @refinement_started_state,
         profile
       ) do
      :ok
    else
      {:error, {:transition_not_allowed, from_state, @refinement_started_state, profile}}
    end
  end

  @spec continue_with_issue?(Issue.t() | term(), function(), [String.t()] | map()) ::
          {:continue, Issue.t()} | {:done, term()} | {:done, term(), atom()} | {:error, term()}
  def continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, continuation_settings) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        continuation_decision(refreshed_issue, continuation_settings)

      {:ok, []} ->
        {:done, issue, :missing}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  def continue_with_issue?(issue, _issue_state_fetcher, _active_states), do: {:done, issue, :invalid_issue}

  defp continuation_decision(%Issue{} = issue, active_states) when is_list(active_states) do
    if active_issue_state?(issue.state, active_states), do: {:continue, issue}, else: {:done, issue, :inactive_state}
  end

  defp continuation_decision(%Issue{} = issue, settings) when is_map(settings) do
    current_profile = Map.get(settings, :current_profile)
    refreshed_profile = profile_for_state(issue.state, settings)

    cond do
      terminal_issue_state?(issue.state, Map.get(settings, :terminal_states, [])) ->
        {:done, issue, :terminal_state}

      !active_issue_state?(issue.state, Map.get(settings, :active_states, [])) ->
        {:done, issue, :inactive_state}

      human_review_state?(issue.state, settings) ->
        {:done, issue, :human_review_state}

      blank?(refreshed_profile) ->
        {:done, issue, :missing_workflow_profile}

      refreshed_profile != current_profile ->
        {:done, issue, :profile_changed}

      !executable_state?(issue.state, settings) ->
        {:done, issue, :non_executable_state}

      true ->
        {:continue, issue}
    end
  end

  @spec selected_worker_host(String.t() | nil, [String.t()] | term()) :: String.t() | nil
  def selected_worker_host(nil, []), do: nil

  def selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  def selected_worker_host(preferred_host, _configured_hosts) when is_binary(preferred_host) and preferred_host != "", do: preferred_host
  def selected_worker_host(_preferred_host, _configured_hosts), do: nil

  @spec failure_summary(term()) :: String.t()
  def failure_summary({:workspace_hook_timeout, hook_name, timeout_ms, details}) do
    elapsed_ms = if is_map(details), do: Map.get(details, :elapsed_ms), else: nil
    output = if is_map(details), do: Map.get(details, :recent_output, ""), else: ""

    "workspace_hook_timeout hook=#{hook_name} timeout_ms=#{timeout_ms} elapsed_ms=#{elapsed_ms} output=#{compact_output(output)}"
  end

  def failure_summary(reason), do: reason |> inspect(limit: 20, printable_limit: 1_000) |> compact_output()

  defp matching_transition?(%{} = transition, from_state, to_state, profile) do
    transition_profile = Map.get(transition, "profile")
    actor = Map.get(transition, "actor")

    normalize_issue_state(Map.get(transition, "from", "")) == normalize_issue_state(from_state) &&
      normalize_issue_state(Map.get(transition, "to", "")) == normalize_issue_state(to_state) &&
      transition_profile in [nil, profile] &&
      actor in [nil, "codex", "symphony"]
  end

  defp matching_transition?(_transition, _from_state, _to_state, _profile), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) and is_list(active_states) do
    normalized_state = normalize_issue_state(state_name)
    Enum.any?(active_states, fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name, _active_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) and is_list(terminal_states) do
    normalized_state = normalize_issue_state(state_name)
    Enum.any?(terminal_states, fn terminal_state -> normalize_issue_state(terminal_state) == normalized_state end)
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp human_review_state?(state_name, settings) do
    case Map.get(settings, :human_review_state?) do
      fun when is_function(fun, 1) -> fun.(state_name)
      _ -> false
    end
  end

  defp profile_for_state(state_name, settings) do
    case Map.get(settings, :profile_for_state) do
      fun when is_function(fun, 1) -> fun.(state_name)
      _ -> nil
    end
  end

  defp executable_state?(state_name, settings) do
    case Map.get(settings, :executor_for_state) do
      fun when is_function(fun, 1) -> fun.(state_name) in ["codex_agent", "backend_action"]
      _ -> true
    end
  end

  defp blank?(value), do: !is_binary(value) or String.trim(value) == ""

  defp normalize_issue_state(state_name) when is_binary(state_name), do: SymphonyElixir.StateName.normalize(state_name)
  defp normalize_issue_state(_state_name), do: ""

  defp compact_output(output) do
    output
    |> to_string()
    |> String.replace("\r", "\n")
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-8)
    |> Enum.join(" | ")
    |> String.slice(0, 1_000)
  end
end

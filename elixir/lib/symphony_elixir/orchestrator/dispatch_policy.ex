defmodule SymphonyElixir.Orchestrator.DispatchPolicy do
  @moduledoc """
  Pure dispatch decisions for the orchestrator.

  The GenServer owns timers, persistence, and worker side effects. This module
  owns deterministic scheduling choices from already-loaded runtime settings.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  @type dispatch_settings :: %{
          optional(:active_states) => MapSet.t(),
          optional(:terminal_states) => MapSet.t(),
          optional(:max_concurrent_agents) => pos_integer(),
          optional(:max_concurrent_agents_for_state) => (term() -> pos_integer()),
          optional(:workflow_executor_for_state) => (term() -> String.t() | nil),
          optional(:human_review_state?) => (term() -> boolean()),
          optional(:listening_mode) => :not_listening | :listening_all | :listening_refine_only,
          optional(:refinement_states) => MapSet.t()
        }

  @type worker_settings :: %{
          optional(:ssh_hosts) => [String.t()],
          optional(:max_concurrent_agents_per_host) => pos_integer() | nil
        }

  @spec sort_issues_for_dispatch([term()]) :: [term()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec should_dispatch_issue?(term(), term(), dispatch_settings(), worker_settings()) :: boolean()
  def should_dispatch_issue?(issue, state, dispatch_settings, worker_settings \\ %{})

  def should_dispatch_issue?(
        %Issue{} = issue,
        %State{running: running, claimed: claimed} = state,
        dispatch_settings,
        worker_settings
      )
      when is_map(dispatch_settings) and is_map(worker_settings) do
    active_states = Map.get(dispatch_settings, :active_states, MapSet.new())
    terminal_states = Map.get(dispatch_settings, :terminal_states, MapSet.new())

    candidate_issue?(issue, dispatch_settings) and
      !ready_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state, dispatch_settings) > 0 and
      state_slots_available?(issue, running, dispatch_settings) and
      worker_slots_available?(state, worker_settings) and
      active_issue_state?(issue.state, active_states)
  end

  def should_dispatch_issue?(_issue, _state, _dispatch_settings, _worker_settings), do: false

  @spec revalidate_issue_for_dispatch(Issue.t(), ([String.t()] -> term()), dispatch_settings()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, dispatch_settings)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) and is_map(dispatch_settings) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, dispatch_settings) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _dispatch_settings), do: {:ok, issue}

  @spec dispatch_slots_available?(Issue.t(), State.t(), dispatch_settings()) :: boolean()
  def dispatch_slots_available?(%Issue{} = issue, %State{} = state, dispatch_settings)
      when is_map(dispatch_settings) do
    available_slots(state, dispatch_settings) > 0 and
      state_slots_available?(issue, state.running, dispatch_settings)
  end

  @spec state_slots_available?(term(), term(), dispatch_settings()) :: boolean()
  def state_slots_available?(%Issue{state: issue_state}, running, dispatch_settings)
      when is_map(running) and is_map(dispatch_settings) do
    limit = state_limit(issue_state, dispatch_settings)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _running, _dispatch_settings), do: false

  @spec select_worker_host(State.t(), String.t() | nil, worker_settings()) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host(%State{} = state, preferred_worker_host, worker_settings \\ %{})
      when is_map(worker_settings) do
    case Map.get(worker_settings, :ssh_hosts, []) do
      [] ->
        nil

      hosts when is_list(hosts) ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1, worker_settings))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  @spec worker_slots_available?(State.t(), worker_settings()) :: boolean()
  def worker_slots_available?(%State{} = state, worker_settings \\ %{}) when is_map(worker_settings) do
    select_worker_host(state, nil, worker_settings) != :no_worker_capacity
  end

  @spec worker_slots_available?(State.t(), String.t() | nil, worker_settings()) :: boolean()
  def worker_slots_available?(%State{} = state, preferred_worker_host, worker_settings)
      when is_map(worker_settings) do
    select_worker_host(state, preferred_worker_host, worker_settings) != :no_worker_capacity
  end

  @spec candidate_issue?(term(), dispatch_settings()) :: boolean()
  def candidate_issue?(
        %Issue{
          id: id,
          identifier: identifier,
          title: title,
          state: state_name
        } = issue,
        dispatch_settings
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) and
             is_map(dispatch_settings) do
    active_states = Map.get(dispatch_settings, :active_states, MapSet.new())
    terminal_states = Map.get(dispatch_settings, :terminal_states, MapSet.new())

    issue_routable_to_worker?(issue) and
      allowed_by_listening_mode?(state_name, dispatch_settings) and
      active_issue_state?(state_name, active_states) and
      !human_review_state?(state_name, dispatch_settings) and
      executable_state?(state_name, dispatch_settings) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  def candidate_issue?(_issue, _dispatch_settings), do: false

  @spec retry_candidate_issue?(Issue.t(), dispatch_settings()) :: boolean()
  def retry_candidate_issue?(%Issue{} = issue, dispatch_settings) when is_map(dispatch_settings) do
    terminal_states = Map.get(dispatch_settings, :terminal_states, MapSet.new())

    candidate_issue?(issue, dispatch_settings) and
      !ready_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  @spec ready_issue_blocked_by_non_terminal?(term(), MapSet.t()) :: boolean()
  def ready_issue_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states
      )
      when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "ready" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def ready_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec terminal_issue_state?(term(), MapSet.t()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @spec active_issue_state?(term(), MapSet.t()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  def active_issue_state?(_state_name, _active_states), do: false

  @spec allowed_by_listening_mode?(term(), dispatch_settings()) :: boolean()
  def allowed_by_listening_mode?(state_name, dispatch_settings) when is_binary(state_name) and is_map(dispatch_settings) do
    case Map.get(dispatch_settings, :listening_mode, :listening_all) do
      :listening_refine_only ->
        dispatch_settings
        |> Map.get(:refinement_states, MapSet.new(["refining"]))
        |> MapSet.member?(normalize_issue_state(state_name))

      :not_listening ->
        false

      _ ->
        true
    end
  end

  def allowed_by_listening_mode?(_state_name, _dispatch_settings), do: false

  @spec normalized_state_set([term()]) :: MapSet.t()
  def normalized_state_set(states) when is_list(states) do
    states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  def normalized_state_set(_states), do: MapSet.new()

  defp available_slots(%State{} = state, dispatch_settings) do
    max_agents =
      state.max_concurrent_agents ||
        Map.get(dispatch_settings, :max_concurrent_agents, 0)

    max(max_agents - map_size(state.running), 0)
  end

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp state_limit(issue_state, dispatch_settings) do
    case Map.get(dispatch_settings, :max_concurrent_agents_for_state) do
      fun when is_function(fun, 1) -> fun.(issue_state)
      _ -> Map.get(dispatch_settings, :max_concurrent_agents, 1)
    end
  end

  defp executable_state?(state_name, dispatch_settings) when is_binary(state_name) do
    executor =
      case Map.get(dispatch_settings, :workflow_executor_for_state) do
        fun when is_function(fun, 1) -> fun.(state_name)
        _ -> "codex_agent"
      end

    executor in ["codex_agent", "backend_action"]
  end

  defp human_review_state?(state_name, dispatch_settings) do
    case Map.get(dispatch_settings, :human_review_state?) do
      fun when is_function(fun, 1) -> fun.(state_name)
      _ -> false
    end
  end

  @spec issue_routable_to_worker?(term()) :: boolean()
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  defp worker_host_slots_available?(%State{} = state, worker_host, worker_settings)
       when is_binary(worker_host) do
    case Map.get(worker_settings, :max_concurrent_agents_per_host) do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    SymphonyElixir.StateName.normalize(state_name)
  end

  defp normalize_issue_state(_state_name), do: ""
end

defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{
    AgentRunner,
    BlockingDecision,
    Codex.RateLimitGate,
    Codex.Update,
    Config,
    MergeConflictReconciler,
    Nap.Results,
    Payload,
    PersistenceProvider,
    PromptBuilder,
    RunLifecycle,
    StatusDashboard,
    Tracker,
    WorkflowStore,
    Workspace,
    WorkspaceDiskGuard
  }

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.DispatchPolicy
  alias SymphonyElixir.Orchestrator.Events
  alias SymphonyElixir.Orchestrator.InputBlocker
  alias SymphonyElixir.Orchestrator.RetryPolicy
  alias SymphonyElixir.Orchestrator.SessionHistory

  @retry_due_at_display_grace_ms 400
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @mergeability_checks_per_poll 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule RunningIssue do
    @moduledoc false

    defstruct [
      :pid,
      :ref,
      :run_id,
      :identifier,
      :issue,
      :project_id,
      :worker_host,
      :workspace_path,
      :session_id,
      :last_codex_message,
      :last_codex_timestamp,
      :last_codex_event,
      :codex_app_server_pid,
      :started_at,
      :agent_result,
      kind: :issue,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: 0,
      session_history: [],
      session_history_total_count: 0,
      linear_state_transitions: [],
      implementation_handoff_completed: false
    ]

    @type t :: %__MODULE__{}
  end

  defmodule RunningOperator do
    @moduledoc false

    defstruct [
      :kind,
      :profile,
      :label,
      :pid,
      :ref,
      :run_id,
      :identifier,
      :issue_id,
      :issue,
      :project_id,
      :state,
      :worker_host,
      :workspace_path,
      :session_id,
      :last_codex_message,
      :last_codex_timestamp,
      :last_codex_event,
      :codex_app_server_pid,
      :started_at,
      :agent_result,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: 0,
      session_history: [],
      session_history_total_count: 0
    ]

    @type t :: %__MODULE__{}
  end

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      blocked: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      codex_rate_limit_observation: nil,
      rate_limit_gate: nil,
      rate_limit_gate_event_fingerprint: nil,
      last_config_error: nil,
      listening_mode: :not_listening,
      operator_tasks: %{}
    ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec worker_task_finished(String.t(), GenServer.server()) :: :ok
  def worker_task_finished(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.cast(server, {:worker_task_finished, issue_id})
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)

    state =
      case runtime_config() do
        {:ok, config} ->
          run_terminal_workspace_cleanup()
          RunLifecycle.close_stale_running_runs(persistence())

          %State{
            poll_interval_ms: config.polling.interval_ms,
            max_concurrent_agents: Config.panel_max_concurrent_agents(),
            next_poll_due_at_ms: now_ms,
            poll_check_in_progress: false,
            tick_timer_ref: nil,
            tick_token: nil,
            codex_totals: @empty_codex_totals,
            codex_rate_limits: nil,
            codex_rate_limit_observation: nil
          }
          |> restore_persistent_blocked()
          |> schedule_tick(config.polling.interval_ms)

        {:error, reason} ->
          Logger.error("Orchestrator started with invalid runtime configuration; listening is disabled: #{config_validation_error_message(reason)}")

          %State{
            poll_interval_ms: 30_000,
            max_concurrent_agents: 0,
            next_poll_due_at_ms: now_ms,
            poll_check_in_progress: false,
            tick_timer_ref: nil,
            tick_token: nil,
            codex_totals: @empty_codex_totals,
            codex_rate_limits: nil,
            codex_rate_limit_observation: nil,
            last_config_error: reason
          }
          |> schedule_tick(30_000)
      end

    {:ok, state}
  end

  @impl true
  def handle_cast({:worker_task_finished, issue_id}, state) when is_binary(issue_id) do
    {:noreply, complete_issue(state, issue_id)}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state) when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = if listening?(state), do: maybe_dispatch(state), else: state
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          state
          |> handle_worker_down_reason(issue_id, running_entry, reason, session_id)
          |> maybe_start_queued_operator_tasks()

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} exit=#{agent_exit_summary(reason, running_entry)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:agent_runner_finished, issue_id, result}, %{running: running} = state)
      when is_binary(issue_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {:noreply,
         %{
           state
           | running: Map.put(running, issue_id, Map.put(running_entry, :agent_result, result))
         }}
    end
  end

  def handle_info(
        {:linear_task_update_result, issue_id, result, tool_result, references, target_state},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      %RunningIssue{} = entry ->
        {:noreply,
         handle_linear_task_update_result(
           state,
           issue_id,
           entry,
           result,
           tool_result,
           references,
           target_state
         )}

      _missing ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> append_session_history(:workspace_ready, "Workspace ready", %{
            workspace_path: runtime_info[:workspace_path],
            worker_host: runtime_info[:worker_host]
          })

        persist_workspace_update(updated_running_entry)
        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:system_worker_update, issue_id, update}, %{running: running} = state)
      when is_binary(issue_id) and is_map(update) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry = append_system_history(running_entry, update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        persist_codex_update(updated_running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update, running_entry.project_id)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:linear_state_transition, issue_id, transition}, %{running: running} = state)
      when is_binary(issue_id) and is_map(transition) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        transitions = [transition | Map.get(running_entry, :linear_state_transitions, [])]

        updated_entry =
          running_entry
          |> Map.put(:linear_state_transitions, transitions)
          |> put_in([Access.key(:issue), Access.key(:state)], Map.get(transition, :to_state))
          |> append_session_history(:linear_state_transition, "Linear state moved", %{
            from_state: Map.get(transition, :from_state),
            to_state: Map.get(transition, :to_state),
            source: Map.get(transition, :source)
          })

        persist_event("linear.state_transition", running_entry.identifier, %{
          issue_id: issue_id,
          from_state: Map.get(transition, :from_state),
          to_state: Map.get(transition, :to_state),
          source: inspect(Map.get(transition, :source))
        })

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_entry)}}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_linear_task_update_result(
         state,
         issue_id,
         entry,
         result,
         tool_result,
         references,
         target_state
       ) do
    blocker = tool_result |> blocker_value() |> BlockingDecision.normalize_blocker()

    cond do
      is_binary(blocker) ->
        persist_and_block_issue(
          state,
          issue_id,
          entry,
          :reported_blocker,
          blocker,
          references
        )

      match?({:error, _}, result) and
          BlockingDecision.terminal_handoff_failure?(elem(result, 1)) ->
        {decision_reason, evidence} = handoff_blocking_decision(elem(result, 1))

        persist_and_block_issue(
          state,
          issue_id,
          entry,
          decision_reason,
          evidence,
          references
        )

      match?({:ok, %{"handoff" => _}}, result) ->
        updated = %{entry | implementation_handoff_completed: true}
        _ = BlockingDecision.clear(entry.identifier)
        %{state | running: Map.put(state.running, issue_id, updated)}

      is_binary(target_state) and match?({:ok, _}, result) ->
        _ = BlockingDecision.clear(entry.identifier)
        state

      true ->
        state
    end
  end

  defp handoff_blocking_decision({:handoff_failed, {:push_permission_blocked, detail}}),
    do: {:push_permission_blocked, "MANUAL_HANDOFF_REQUIRED: #{detail}"}

  defp handoff_blocking_decision(reason),
    do: {:implementation_handoff_failure, inspect(reason)}

  defp handle_worker_down_reason(
         state,
         run_id,
         %RunningOperator{} = running_entry,
         reason,
         session_id
       ) do
    handle_operator_down_reason(state, run_id, running_entry, reason, session_id)
  end

  defp handle_worker_down_reason(
         state,
         issue_id,
         %RunningIssue{} = running_entry,
         reason,
         session_id
       ) do
    handle_issue_worker_down_reason(state, issue_id, running_entry, reason, session_id)
  end

  defp handle_issue_worker_down_reason(
         state,
         issue_id,
         %{agent_result: {:error, reason}} = running_entry,
         :normal,
         session_id
       ) do
    handle_agent_domain_failure(state, issue_id, running_entry, reason, session_id)
  end

  defp handle_issue_worker_down_reason(state, issue_id, running_entry, :normal, session_id) do
    persist_run_finished(running_entry, "completed", nil)

    if run_made_progress?(running_entry) do
      _ = BlockingDecision.clear(running_entry.identifier)
      schedule_continuation(state, issue_id, running_entry, session_id)
    else
      case BlockingDecision.advance_no_progress(
             running_entry.identifier,
             running_entry.run_id,
             run_references(running_entry)
           ) do
        {:blocked, decision} ->
          block_from_decision(state, issue_id, running_entry, decision)

        {:streak, streak} ->
          persist_event(
            "run.no_progress",
            running_entry.identifier,
            %{streak: streak},
            running_entry.run_id
          )

          schedule_continuation(state, issue_id, running_entry, session_id)

        {:error, reason} ->
          Logger.error("Unable to persist no-progress decision issue_id=#{issue_id} run_id=#{running_entry.run_id} reason=#{inspect(reason)}")

          state |> complete_issue(issue_id)
      end
    end
  end

  defp handle_issue_worker_down_reason(state, issue_id, running_entry, reason, session_id) do
    Logger.warning("Agent task crashed for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}; scheduling retry")

    next_attempt = RetryPolicy.next_retry_attempt_from_running(running_entry)
    summary = "agent crashed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: summary,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
    |> tap(fn _state -> persist_run_finished(running_entry, "failed", summary) end)
  end

  defp schedule_continuation(state, issue_id, running_entry, session_id) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

    state
    |> complete_issue(issue_id)
    |> schedule_issue_retry(issue_id, 1, %{
      identifier: running_entry.identifier,
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp run_made_progress?(running_entry) do
    running_entry.linear_state_transitions != [] or running_entry.implementation_handoff_completed
  end

  defp blocker_value(result) when is_map(result),
    do: Payload.get_any(result, ["blockers", :blockers])

  defp blocker_value(_result), do: nil

  defp persist_and_block_issue(state, issue_id, running_entry, reason, evidence, references) do
    case BlockingDecision.decide(
           running_entry.identifier,
           reason,
           evidence,
           running_entry.run_id,
           references
         ) do
      {:ok, decision} ->
        block_from_decision(state, issue_id, running_entry, decision)

      {:error, persist_reason} ->
        Logger.error("Blocking decision persistence failed issue_id=#{issue_id} run_id=#{running_entry.run_id} reason=#{inspect(persist_reason)}")

        state
    end
  end

  defp block_from_decision(state, issue_id, running_entry, decision) do
    stop_running_process(running_entry)
    delivery = BlockingDecision.deliver(issue_id, running_entry.identifier)

    persist_event(
      "run.blocked",
      running_entry.identifier,
      %{
        issue_id: issue_id,
        decision: decision,
        delivery_result: inspect(delivery)
      },
      running_entry.run_id
    )

    blocked_entry = %{
      issue_id: issue_id,
      identifier: running_entry.identifier,
      state:
        if(delivery_transition_completed?(delivery),
          do: "Blocked",
          else: running_entry.issue.state
        ),
      run_id: running_entry.run_id,
      blocked_at: decision["decided_at"],
      reason: decision["reason"],
      detail: decision["evidence"],
      worker_host: running_entry.worker_host,
      workspace_path: running_entry.workspace_path,
      session_id: running_entry.session_id,
      session_history: [],
      session_history_total_count: 0
    }

    cancel_issue_retry(state, issue_id)
    |> Map.update!(:running, &Map.delete(&1, issue_id))
    |> Map.update!(:blocked, &Map.put(&1, issue_id, blocked_entry))
    |> Map.update!(:claimed, &MapSet.put(&1, issue_id))
  end

  defp delivery_transition_completed?({:ok, %{transition: :ok}}), do: true
  defp delivery_transition_completed?(_delivery), do: false

  defp run_references(running_entry) do
    %{worker_host: running_entry.worker_host, workspace_path: running_entry.workspace_path}
  end

  defp cancel_issue_retry(state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _ -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp handle_operator_down_reason(
         state,
         run_id,
         %{agent_result: :ok} = running_entry,
         :normal,
         session_id
       ) do
    Logger.info("Operator task completed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id}")

    running_entry =
      append_session_history(
        running_entry,
        :operator_task_completed,
        "Operator task completed",
        %{
          source: :system,
          run_id: run_id,
          kind: running_entry_kind(running_entry)
        }
      )

    persist_run_finished(running_entry, "completed", nil)
    finish_operator_task(state, running_entry, :completed, nil)
  end

  defp handle_operator_down_reason(
         state,
         run_id,
         %{agent_result: {:error, reason}} = running_entry,
         :normal,
         session_id
       ) do
    summary = agent_failure_summary(reason)

    Logger.warning("Operator task failed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id} #{summary}")

    running_entry =
      append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
        source: :system,
        run_id: run_id,
        kind: running_entry_kind(running_entry),
        reason: summary
      })

    persist_run_finished(running_entry, "failed", summary)
    finish_operator_task(state, running_entry, :failed, summary)
  end

  defp handle_operator_down_reason(state, run_id, running_entry, :normal, session_id) do
    Logger.info("Operator task completed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id}")

    persist_run_finished(running_entry, "completed", nil)
    finish_operator_task(state, running_entry, :completed, nil)
  end

  defp handle_operator_down_reason(state, run_id, running_entry, reason, session_id) do
    summary = "operator task crashed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"

    Logger.warning("Operator task crashed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id} #{summary}")

    running_entry =
      append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
        source: :system,
        run_id: run_id,
        kind: running_entry_kind(running_entry),
        reason: summary
      })

    persist_run_finished(running_entry, "failed", summary)
    finish_operator_task(state, running_entry, :failed, summary)
  end

  defp handle_agent_domain_failure(state, issue_id, running_entry, reason, session_id) do
    if InputBlocker.blocked?(reason) do
      block_issue_for_input(state, issue_id, running_entry, reason, session_id)
    else
      summary = agent_failure_summary(reason)

      Logger.warning("Agent task failed for issue_id=#{issue_id} session_id=#{session_id} #{summary}; scheduling retry")

      next_attempt = RetryPolicy.next_retry_attempt_from_running(running_entry)

      schedule_issue_retry(state, issue_id, next_attempt, %{
        identifier: running_entry.identifier,
        error: summary,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
      |> tap(fn _state -> persist_run_finished(running_entry, "failed", summary) end)
    end
  end

  defp block_issue_for_input(state, issue_id, running_entry, reason, session_id) do
    summary = InputBlocker.summary(reason)

    Logger.warning("Agent task blocked for issue_id=#{issue_id} session_id=#{session_id} #{summary}; waiting for operator input")

    updated_running_entry =
      append_session_history(
        running_entry,
        InputBlocker.event(reason),
        InputBlocker.label(reason),
        %{message: blocked_payload(reason), source: :agent}
      )

    blocked_entry = InputBlocker.entry(issue_id, Map.from_struct(updated_running_entry), reason)

    persist_event(
      "run.blocked",
      running_entry.identifier,
      %{issue_id: issue_id, reason: summary},
      Map.get(running_entry, :run_id)
    )

    persist_run_finished(updated_running_entry, "blocked", summary)

    %{
      state
      | blocked: Map.put(state.blocked, issue_id, blocked_entry),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id)
    }
  end

  defp blocked_payload({reason, payload})
       when reason in [:turn_input_required, :approval_required] and is_map(payload), do: payload

  defp blocked_payload(reason), do: %{event: reason}

  defp agent_exit_summary(:normal, %{agent_result: :ok}), do: "completed"

  defp agent_exit_summary(:normal, %{agent_result: {:error, reason}}),
    do: "failed #{agent_failure_summary(reason)}"

  defp agent_exit_summary(:normal, _running_entry), do: "completed"

  defp agent_exit_summary(reason, _running_entry),
    do: "crashed #{inspect(reason, limit: 20, printable_limit: 1_000)}"

  defp agent_failure_summary({:workspace_hook_timeout, hook_name, timeout_ms, details}) do
    elapsed_ms = if is_map(details), do: Map.get(details, :elapsed_ms), else: nil
    output = if is_map(details), do: Map.get(details, :recent_output, ""), else: ""
    setting = timeout_setting_hint(hook_name)

    "class=workspace_hook_timeout hook=#{hook_name} timeout_ms=#{timeout_ms} elapsed_ms=#{elapsed_ms} setting=#{setting} output=#{compact_log_output(output)}"
  end

  defp agent_failure_summary(reason),
    do: "class=agent_domain_failure reason=#{compact_log_output(inspect(reason, limit: 20, printable_limit: 1_000))}"

  defp timeout_setting_hint("project_bootstrap"),
    do: "Settings / Workflow / Bootstrap / Initialize timeout ms"

  defp timeout_setting_hint(_hook_name),
    do: "Settings / Workflow / Lifecycle Hooks / Hook timeout ms"

  defp compact_log_output(output) do
    output
    |> to_string()
    |> String.replace("\r", "\n")
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-8)
    |> Enum.join(" | ")
    |> String.slice(0, 1_000)
  end

  defp maybe_dispatch(%State{} = state) do
    Logger.debug("event=poll_heartbeat listening_mode=#{listening_mode(state)} tick_timestamp=#{System.system_time(:millisecond)}")

    state =
      state
      |> reconcile_stale_operator_entries()
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()
      |> refresh_deployment_capacity()

    workflows = WorkflowStore.list_enabled()

    if workflows == [] do
      handle_dispatch_error(state, :setup_required)
    else
      Enum.reduce(workflows, state, &dispatch_workflow/2)
    end
  end

  defp dispatch_workflow(workflow, state) do
    Config.with_workflow_context(workflow, fn ->
      dispatch_for_workflow(state, workflow)
    end)
  end

  defp dispatch_for_workflow(%State{} = state, %{config: _config} = workflow) do
    with :ok <- Config.validate!(),
         state = reconcile_ready_to_merge_issues(state),
         :allow <- rate_limit_gate_allows_dispatch(state),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0,
         true <- workflow_slots_available?(state, workflow) do
      Logger.info(
        "event=poll_workflow_decision listening_mode=#{listening_mode(state)} workflow=#{workflow_name(workflow)} candidate_fetch=success candidate_count=#{length(issues)} dispatch=attempted"
      )

      state = %{state | last_config_error: nil}
      persist_polled_issues(issues)
      choose_issues(issues, state)
    else
      {:error, reason} ->
        Logger.warning("event=poll_workflow_decision listening_mode=#{listening_mode(state)} workflow=#{workflow_name(workflow)} candidate_fetch=failed reason=#{inspect(reason)} dispatch=blocked")
        handle_dispatch_error(state, reason)

      {:block, details} ->
        state
        |> apply_rate_limit_gate_block(details)
        |> Map.put(:last_config_error, nil)

      false ->
        Logger.info("event=poll_workflow_decision listening_mode=#{listening_mode(state)} workflow=#{workflow_name(workflow)} candidate_fetch=success dispatch=skipped reason=capacity")
        %{state | last_config_error: nil}
    end
  end

  defp reconcile_ready_to_merge_issues(%State{} = state) do
    case Tracker.fetch_issues_by_states(["Ready to Merge"]) do
      {:ok, issues} ->
        persist_polled_issues(issues)

        issues
        |> Enum.take(@mergeability_checks_per_poll)
        |> Enum.reduce(state, fn
          %Issue{} = issue, state_acc -> reconcile_ready_to_merge_issue(state_acc, issue)
          _issue, state_acc -> state_acc
        end)

      {:error, reason} ->
        Logger.error("Failed to fetch Ready to Merge issues for mergeability reconciliation: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_ready_to_merge_issue(state, issue) do
    case MergeConflictReconciler.reconcile(issue, Config.settings!().project) do
      {:blocked, decision, delivery} ->
        blocked_entry = %{
          issue_id: issue.id,
          identifier: issue.identifier,
          state: if(delivery_transition_completed?(delivery), do: "Blocked", else: issue.state),
          run_id: decision["run_id"],
          blocked_at: decision["decided_at"],
          reason: decision["reason"],
          detail: decision["evidence"],
          worker_host: nil,
          workspace_path: nil,
          session_id: nil,
          session_history: [],
          session_history_total_count: 0
        }

        state
        |> Map.update!(:blocked, &Map.put(&1, issue.id, blocked_entry))
        |> Map.update!(:claimed, &MapSet.put(&1, issue.id))

      _result ->
        state
    end
  end

  defp workflow_slots_available?(%State{} = state, _workflow), do: available_slots(state) > 0

  defp handle_dispatch_error(%State{} = state, reason) do
    if config_validation_error?(reason) do
      log_config_error_once(state, reason)
    else
      Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
      %{state | last_config_error: nil}
    end
  end

  defp log_config_error_once(%State{last_config_error: reason} = state, reason), do: state

  defp log_config_error_once(%State{} = state, reason) do
    Logger.error(config_validation_error_message(reason))
    %{state | last_config_error: reason}
  end

  defp config_validation_error?(:missing_linear_api_token), do: true
  defp config_validation_error?(:missing_linear_endpoint), do: true
  defp config_validation_error?(:missing_linear_project_slug), do: true
  defp config_validation_error?(:missing_project_repository_url), do: true
  defp config_validation_error?(:missing_tracker_kind), do: true
  defp config_validation_error?(:setup_required), do: true
  defp config_validation_error?(:workflow_front_matter_not_a_map), do: true
  defp config_validation_error?({:unsupported_tracker_kind, _kind}), do: true
  defp config_validation_error?({:invalid_workflow_config, _message}), do: true
  defp config_validation_error?({:missing_workflow_file, _path, _reason}), do: true
  defp config_validation_error?({:workflow_parse_error, _reason}), do: true
  defp config_validation_error?(_reason), do: false

  defp config_validation_error_message(:missing_linear_api_token),
    do: "Linear API token missing in runtime environment"

  defp config_validation_error_message(:missing_linear_endpoint),
    do: "Linear endpoint missing in runtime tracker settings"

  defp config_validation_error_message(:missing_linear_project_slug),
    do: "Linear project slug missing in Project Settings"

  defp config_validation_error_message(:missing_project_repository_url),
    do: "Project repository URL missing in Project Settings"

  defp config_validation_error_message(:missing_tracker_kind),
    do: "Tracker kind missing in runtime tracker settings"

  defp config_validation_error_message(:setup_required),
    do: "No workflow is configured. Open /settings/workflow to create one."

  defp config_validation_error_message(:workflow_front_matter_not_a_map) do
    "Failed to parse workflow config: front matter must decode to a map"
  end

  defp config_validation_error_message({:unsupported_tracker_kind, kind}) do
    "Unsupported tracker kind in runtime tracker settings: #{inspect(kind)}"
  end

  defp config_validation_error_message({:invalid_workflow_config, message}) do
    "Invalid workflow config: #{message}"
  end

  defp config_validation_error_message({:missing_workflow_file, path, reason}) do
    "Missing workflow file at #{path}: #{inspect(reason)}"
  end

  defp config_validation_error_message({:workflow_parse_error, reason}) do
    "Failed to parse workflow config: #{inspect(reason)}"
  end

  defp config_validation_error_message(reason), do: inspect(reason)

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = issue_running_ids(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc """
  Reconciles already-refreshed issue states against the current runtime state.

  This is a side-effecting runtime boundary used by the orchestrator and
  integration tests. It may stop active tasks and clean workspaces according to
  the configured active and terminal state sets.
  """
  @spec reconcile_issue_states([Issue.t()], term()) :: term()
  def reconcile_issue_states(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !DispatchPolicy.issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_blocked_issues(%State{blocked: blocked} = state) when map_size(blocked) == 0,
    do: state

  defp reconcile_blocked_issues(%State{blocked: blocked} = state) do
    blocked_ids = Map.keys(blocked)

    case Tracker.fetch_issue_states_by_ids(blocked_ids) do
      {:ok, issues} ->
        issues
        |> reconcile_blocked_issue_states(state, active_state_set(), terminal_state_set())
        |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

      {:error, reason} ->
        Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked claims")

        state
    end
  end

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      SymphonyElixir.StateName.normalize(issue.state) == "blocked" ->
        _ = retry_blocked_delivery(issue)
        refresh_blocked_issue_state(state, issue)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing blocked claim")

        _ = BlockingDecision.clear(issue.identifier)
        release_blocked_issue(state, issue.id)

      !DispatchPolicy.issue_routable_to_worker?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing blocked claim")

        _ = BlockingDecision.clear(issue.identifier)
        release_blocked_issue(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        Logger.info("Blocked issue recovered to active state: #{issue_context(issue)} state=#{issue.state}; clearing decision")

        _ = BlockingDecision.clear(issue.identifier)
        release_blocked_issue(state, issue.id)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing blocked claim")

        _ = BlockingDecision.clear(issue.identifier)
        release_blocked_issue(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp retry_blocked_delivery(%Issue{id: issue_id, identifier: identifier}) do
    case BlockingDecision.deliver(issue_id, identifier) do
      {:ok, _delivery} ->
        :ok

      {:error, reason} ->
        Logger.error("Blocking decision delivery retry failed issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")

        {:error, reason}
    end
  end

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id),
        do: state_acc,
        else: release_blocked_issue(state_acc, issue_id)
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{} = blocked_entry ->
        %{
          state
          | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | state: issue.state})
        }

      _ ->
        state
    end
  end

  defp release_blocked_issue(%State{} = state, issue_id) do
    %{
      state
      | blocked: Map.delete(state.blocked, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp restore_persistent_blocked(%State{} = state) do
    persistence = persistence()

    case PersistenceProvider.read(fn -> persistence.list_blocked_issues() end) do
      issues when is_list(issues) ->
        Enum.reduce(issues, state, &restore_blocked_entry(&1, &2))

      {:error, reason} ->
        Logger.error("Failed to restore persistent blocking decisions reason=#{inspect(reason)}")
        state
    end
  end

  defp restore_blocked_entry(issue, acc) do
    decision = Map.get(issue, :blocking_decision) || %{}
    issue_id = Map.get(issue, :tracker_issue_id)

    if is_binary(issue_id) do
      entry = %{
        issue_id: issue_id,
        identifier: Map.get(issue, :identifier),
        state: Map.get(issue, :state) || "Blocked",
        run_id: decision["run_id"],
        blocked_at: decision["decided_at"],
        reason: decision["reason"],
        detail: decision["evidence"],
        worker_host: nil,
        workspace_path: nil,
        session_id: nil,
        session_history: [],
        session_history_total_count: 0
      }

      %{
        acc
        | blocked: Map.put(acc.blocked, issue_id, entry),
          claimed: MapSet.put(acc.claimed, issue_id)
      }
    else
      acc
    end
  end

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        persist_run_finished(running_entry, "stopped", nil)

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    if map_size(state.running) == 0 do
      state
    else
      reconcile_stalled_running_issues(state, Config.settings!().codex.stall_timeout_ms)
    end
  end

  defp reconcile_stalled_running_issues(state, timeout_ms) when timeout_ms <= 0, do: state

  defp reconcile_stalled_running_issues(state, timeout_ms) do
    now = DateTime.utc_now()

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
    end)
  end

  defp restart_stalled_issue(state, _run_id, %RunningOperator{}, _now, _timeout_ms), do: state

  defp restart_stalled_issue(state, issue_id, %RunningIssue{} = running_entry, now, timeout_ms) do
    blocking_reason = InputBlocker.blocked_reason(blocking_signal(running_entry))
    stall_decision = RetryPolicy.stall_decision(issue_id, running_entry, now, timeout_ms)

    case {blocking_reason, stall_decision} do
      {{:blocked, reason, payload}, {:stalled, decision}} ->
        Logger.warning(
          "Issue stalled while waiting for input: issue_id=#{issue_id} issue_identifier=#{decision.identifier} session_id=#{decision.session_id} elapsed_ms=#{decision.elapsed_ms}; marking blocked"
        )

        stop_running_process(running_entry)

        state
        |> record_session_completion_totals(running_entry)
        |> Map.update!(:running, &Map.delete(&1, issue_id))
        |> block_issue_for_input(issue_id, running_entry, {reason, payload}, decision.session_id)

      {_input_state, {:stalled, decision}} ->
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{decision.identifier} session_id=#{decision.session_id} elapsed_ms=#{decision.elapsed_ms}; restarting with backoff")

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, decision.attempt, decision.metadata)

      {_input_state, :active} ->
        state
    end
  end

  defp blocking_signal(running_entry) when is_map(running_entry) do
    cond do
      InputBlocker.blocked?(Map.get(running_entry, :last_codex_event)) ->
        Map.get(running_entry, :last_codex_event)

      InputBlocker.blocked?(Map.get(running_entry, :last_codex_message)) ->
        Map.get(running_entry, :last_codex_message)

      true ->
        nil
    end
  end

  defp stop_running_process(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :pid) do
      pid when is_pid(pid) -> terminate_task(pid)
      _ -> :ok
    end

    case Map.get(running_entry, :ref) do
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    dispatch_settings = dispatch_policy_settings(state)
    worker_settings = worker_policy_settings()

    issues
    |> DispatchPolicy.sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if DispatchPolicy.should_dispatch_issue?(
           issue,
           state_acc,
           dispatch_settings,
           worker_settings
         ) do
        dispatch_issue(state_acc, issue)
      else
        reasons = DispatchPolicy.skip_reasons(issue, state_acc, dispatch_settings, worker_settings)
        Logger.info("event=dispatch_skip issue_id=#{issue.id} issue_identifier=#{issue.identifier} skip_reason=#{Enum.join(reasons, ",")}")
        state_acc
      end
    end)
  end

  defp listening_mode(%State{} = state), do: listening_mode_string(state)
  defp workflow_name(%{project_id: project_id}), do: project_id

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    DispatchPolicy.terminal_issue_state?(state_name, terminal_states)
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    DispatchPolicy.active_issue_state?(state_name, active_states)
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    SymphonyElixir.StateName.normalize(state_name)
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> DispatchPolicy.normalized_state_set()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> DispatchPolicy.normalized_state_set()
  end

  defp dispatch_policy_settings(%State{} = state) do
    config = Config.settings!()

    DispatchPolicy.build_settings(%{
      active_states: config.tracker.active_states,
      terminal_states: config.tracker.terminal_states,
      refinement_states: refinement_states(config),
      listening_mode: listening_mode_atom(state),
      max_concurrent_agents: state.max_concurrent_agents,
      workflow_executor_for_state: &Config.workflow_executor_for_state/1,
      human_review_state?: &Config.human_review_state?/1
    })
  end

  defp refinement_states(config) do
    routed_states =
      config.workflow
      |> Map.get("states", %{})
      |> Enum.flat_map(fn
        {state_name, %{"profile" => "refinement"}} when is_binary(state_name) -> [state_name]
        {state_name, %{profile: "refinement"}} when is_binary(state_name) -> [state_name]
        _ -> []
      end)
      |> Enum.map(&normalize_issue_state/1)
      |> Enum.reject(&(&1 == ""))

    if routed_states == [], do: ["refining"], else: routed_states
  end

  defp worker_policy_settings do
    config = Config.settings!()

    %{
      ssh_hosts: config.worker.ssh_hosts,
      max_concurrent_agents_per_host: config.worker.max_concurrent_agents_per_host
    }
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case DispatchPolicy.revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           dispatch_policy_settings(state)
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    if Config.execution_mode() == :worker do
      enqueue_issue_for_worker(state, issue, attempt)
    else
      dispatch_issue_centrally(state, issue, attempt, preferred_worker_host)
    end
  end

  defp dispatch_issue_centrally(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp enqueue_issue_for_worker(%State{} = state, %Issue{} = issue, attempt) do
    case persist_worker_task_queued(issue, attempt) do
      {:ok, %{run: run, task: task}} ->
        Logger.info("Queued issue for external worker: #{issue_context(issue)} run_id=#{run.id} task_id=#{task.id}")

        %{
          state
          | claimed: MapSet.put(state.claimed, issue.id),
            max_concurrent_agents: max(state.max_concurrent_agents - 1, 0),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to queue worker task for #{issue_context(issue)}: #{inspect(reason)}")

        persist_event("task.queue_failed", issue.identifier, %{
          issue_id: issue.id,
          error: inspect(reason)
        })

        state
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case ensure_workspace_disk_available(issue) do
      :ok ->
        workflow = current_workflow_context()

        case persist_run_started(issue, attempt, worker_host) do
          {:ok, run_record} ->
            dispatch_issue_agent(
              state,
              issue,
              attempt,
              recipient,
              worker_host,
              workflow,
              run_record
            )

          {:error, reason} ->
            skip_dispatch_for_persistence(state, issue, attempt, worker_host, reason)
        end

      {:error, reason} ->
        block_issue_for_disk_guard(state, issue, reason, worker_host)
    end
  end

  defp dispatch_issue_agent(state, issue, attempt, recipient, worker_host, workflow, run_record) do
    case start_issue_agent_task(state, issue, attempt, recipient, worker_host, workflow) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %RunningIssue{
            pid: pid,
            ref: ref,
            run_id: run_record && run_record.id,
            identifier: issue.identifier,
            issue: issue,
            project_id: Map.get(workflow, :project_id),
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: RetryPolicy.normalize_attempt(attempt),
            started_at: DateTime.utc_now(),
            session_history: initial_session_history(issue, attempt, worker_host),
            session_history_total_count: 1
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")

        persist_event("run.spawn_failed", issue.identifier, %{
          issue_id: issue.id,
          error: inspect(reason)
        })

        failure_reason = "failed to spawn agent: #{inspect(reason)}"

        persist_run_finished(
          %{
            run_id: run_record && run_record.id,
            identifier: issue.identifier,
            issue: issue,
            session_id: nil
          },
          "failed",
          failure_reason
        )

        next_attempt = next_spawn_attempt(attempt)

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: failure_reason,
          worker_host: worker_host
        })
    end
  end

  defp start_operator_task_after_run(state, started, run, workflow) do
    started = if run, do: %{started | run_id: run.id}, else: started

    case select_worker_host(state, nil) do
      :no_worker_capacity ->
        fail_operator_task_start(state, started, "no worker capacity available")

      worker_host ->
        spawn_operator_task_with_disk_guard(state, started, worker_host, workflow)
    end
  end

  defp spawn_operator_task_with_disk_guard(state, started, worker_host, workflow) do
    issue = operator_task_issue(started)

    case ensure_workspace_disk_available(issue) do
      :ok ->
        spawn_operator_task(state, started, worker_host, workflow)

      {:error, reason} ->
        fail_operator_task_start(state, started, format_disk_guard_reason(reason))
    end
  end

  defp skip_dispatch_for_persistence(state, issue, attempt, worker_host, reason) do
    Logger.error("Run-start persistence failed action=skip_dispatch #{issue_context(issue)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")

    schedule_issue_retry(state, issue.id, next_spawn_attempt(attempt), %{
      identifier: issue.identifier,
      error: "run-start persistence failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}",
      worker_host: worker_host
    })
  end

  defp next_spawn_attempt(attempt) when is_integer(attempt), do: attempt + 1
  defp next_spawn_attempt(_attempt), do: nil

  defp start_issue_agent_task(state, issue, attempt, recipient, worker_host, workflow) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      Config.with_workflow_context(workflow, fn ->
        result =
          agent_runner().run(issue, recipient,
            attempt: attempt,
            worker_host: worker_host,
            rate_limit_snapshot: state.codex_rate_limits,
            rate_limit_settings: Config.settings!()
          )

        send(recipient, {:agent_runner_finished, issue.id, result})
        result
      end)
    end)
  end

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id)
    }
  end

  defp ensure_workspace_disk_available(issue) do
    case workspace_disk_guard().check(Config.settings!()) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning("Skipping agent spawn for #{issue_context(issue)}: #{format_disk_guard_reason(reason)}")

        {:error, reason}
    end
  rescue
    error ->
      reason = %{
        reason: :disk_guard_evaluation_failed,
        exception: error.__struct__,
        detail: Exception.message(error)
      }

      Logger.error("Workspace disk guard evaluation failed action=disk_guard_failed #{disk_guard_log_context(issue)} exception=#{inspect(reason.exception)} reason=#{inspect(reason.detail)}")

      {:error, reason}
  end

  defp disk_guard_log_context(%Issue{
         id: run_id,
         assigned_to_worker: false,
         labels: ["operator" | _]
       }),
       do: "run_id=#{run_id}"

  defp disk_guard_log_context(%Issue{} = issue), do: issue_context(issue)

  defp workspace_disk_guard do
    Application.get_env(:symphony_elixir, :workspace_disk_guard_module, WorkspaceDiskGuard)
  end

  defp block_issue_for_disk_guard(%State{} = state, %Issue{} = issue, reason, worker_host) do
    detail = format_disk_guard_reason(reason)

    persist_event("run.blocked", issue.identifier, %{
      issue_id: issue.id,
      reason: "workspace_disk_guard",
      detail: detail,
      root: Map.get(reason, :root),
      free_bytes: Map.get(reason, :free_bytes),
      min_free_bytes: Map.get(reason, :min_free_bytes),
      setting: Map.get(reason, :setting)
    })

    blocked_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      state: issue.state,
      worker_host: worker_host,
      workspace_path: nil,
      session_id: nil,
      blocked_at: DateTime.utc_now(),
      reason: :workspace_disk_guard,
      detail: detail,
      session_history: [
        %{
          at: DateTime.utc_now(),
          source: :system,
          event: "workspace_disk_guard.blocked",
          label: "Workspace disk guard",
          detail: detail,
          severity: :warning
        }
      ],
      session_history_total_count: 1
    }

    %{
      state
      | blocked: Map.put(state.blocked, issue.id, blocked_entry),
        retry_attempts: Map.delete(state.retry_attempts, issue.id),
        claimed: MapSet.put(state.claimed, issue.id)
    }
  end

  defp format_disk_guard_reason(%{reason: :low_disk_space} = reason) do
    "low workspace disk space root=#{Map.get(reason, :root)} free_bytes=#{Map.get(reason, :free_bytes)} min_free_bytes=#{Map.get(reason, :min_free_bytes)} setting=#{Map.get(reason, :setting)}"
  end

  defp format_disk_guard_reason(reason), do: inspect(reason)

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})

    prepared_retry =
      RetryPolicy.prepare_retry(
        issue_id,
        attempt,
        metadata,
        previous_retry,
        Config.settings!().agent.max_retry_backoff_ms
      )

    retry_token = make_ref()

    due_at_ms =
      System.monotonic_time(:millisecond) + prepared_retry.delay_ms +
        @retry_due_at_display_grace_ms

    if is_reference(prepared_retry.old_timer_ref) do
      Process.cancel_timer(prepared_retry.old_timer_ref)
    end

    timer_ref =
      Process.send_after(self(), {:retry_issue, issue_id, retry_token}, prepared_retry.delay_ms)

    if prepared_retry.delay_type == :continuation do
      Logger.info("Scheduling continuation check issue_id=#{issue_id} issue_identifier=#{prepared_retry.identifier} in #{prepared_retry.delay_ms}ms")

      persist_event("run.continuation_scheduled", prepared_retry.identifier, %{
        issue_id: issue_id,
        delay_ms: prepared_retry.delay_ms
      })
    else
      error_suffix =
        if is_binary(prepared_retry.error), do: " error=#{prepared_retry.error}", else: ""

      Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{prepared_retry.identifier} in #{prepared_retry.delay_ms}ms (attempt #{prepared_retry.attempt})#{error_suffix}")

      persist_event("run.retry_scheduled", prepared_retry.identifier, %{
        issue_id: issue_id,
        attempt: prepared_retry.attempt,
        delay_ms: prepared_retry.delay_ms,
        error: prepared_retry.error
      })
    end

    %{
      state
      | retry_attempts:
          Map.put(
            state.retry_attempts,
            issue_id,
            RetryPolicy.retry_entry(prepared_retry, timer_ref, retry_token, due_at_ms)
          ),
        claimed: MapSet.put(state.claimed, issue_id)
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
       when is_reference(retry_token) do
    case RetryPolicy.pop_retry_attempt(state.retry_attempts, issue_id, retry_token) do
      {:ok, attempt, metadata, retry_attempts} ->
        {:ok, attempt, metadata, %{state | retry_attempts: retry_attempts}}

      :missing ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    dispatch_settings = dispatch_policy_settings(state)
    terminal_states = Map.fetch!(dispatch_settings, :terminal_states)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      DispatchPolicy.retry_candidate_issue?(issue, dispatch_settings) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    with :ok <- Config.validate!(),
         {:ok, issues} <-
           Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      issues
      |> Enum.each(fn
        %Issue{identifier: identifier} when is_binary(identifier) ->
          cleanup_issue_workspace(identifier)

        _ ->
          :ok
      end)
    else
      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{config_validation_error_message(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    state = refresh_deployment_capacity(state)
    dispatch_settings = dispatch_policy_settings(state)
    worker_settings = worker_policy_settings()

    if DispatchPolicy.retry_candidate_issue?(issue, dispatch_settings) and
         dispatch_slots_available?(issue, state) and
         DispatchPolicy.worker_slots_available?(state, metadata[:worker_host], worker_settings) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    DispatchPolicy.select_worker_host(state, preferred_worker_host, worker_policy_settings())
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(state.max_concurrent_agents - map_size(state.running), 0)
  end

  defp refresh_deployment_capacity(%State{} = state) do
    capacity =
      case Config.execution_mode() do
        :worker -> persistence().available_worker_slots()
        :centralized -> Config.panel_max_concurrent_agents()
      end

    %{state | max_concurrent_agents: capacity}
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec start_listening() :: map() | :unavailable
  def start_listening, do: start_listening(__MODULE__)

  @spec start_listening(GenServer.server()) :: map() | :unavailable
  def start_listening(server) do
    if Process.whereis(server), do: GenServer.call(server, :start_listening), else: :unavailable
  end

  @spec start_refine_only_listening() :: map() | :unavailable
  def start_refine_only_listening, do: start_refine_only_listening(__MODULE__)

  @spec start_refine_only_listening(GenServer.server()) :: map() | :unavailable
  def start_refine_only_listening(server) do
    if Process.whereis(server),
      do: GenServer.call(server, :start_refine_only_listening),
      else: :unavailable
  end

  @spec stop_listening() :: map() | :unavailable
  def stop_listening, do: stop_listening(__MODULE__)

  @spec stop_listening(GenServer.server()) :: map() | :unavailable
  def stop_listening(server) do
    if Process.whereis(server), do: GenServer.call(server, :stop_listening), else: :unavailable
  end

  @spec request_nap() :: map() | :unavailable
  def request_nap, do: request_nap(nil)

  @spec request_nap(String.t() | nil | GenServer.server()) :: map() | :unavailable
  def request_nap(project_id) when is_binary(project_id) or is_nil(project_id),
    do: request_nap(__MODULE__, project_id)

  def request_nap(server), do: request_nap(server, nil)

  @spec request_nap(GenServer.server(), String.t() | nil) :: map() | :unavailable
  def request_nap(server, project_id) do
    if GenServer.whereis(server),
      do: GenServer.call(server, {:request_operator_task, :nap, project_id}),
      else: :unavailable
  end

  @spec request_day_dreaming() :: map() | :unavailable
  def request_day_dreaming, do: request_day_dreaming(nil)

  @spec request_day_dreaming(String.t() | nil | GenServer.server()) :: map() | :unavailable
  def request_day_dreaming(project_id) when is_binary(project_id) or is_nil(project_id),
    do: request_day_dreaming(__MODULE__, project_id)

  def request_day_dreaming(server), do: request_day_dreaming(server, nil)

  @spec request_day_dreaming(GenServer.server(), String.t() | nil) :: map() | :unavailable
  def request_day_dreaming(server, project_id) do
    if GenServer.whereis(server),
      do: GenServer.call(server, {:request_operator_task, :day_dreaming, project_id}),
      else: :unavailable
  end

  @spec force_stop_all() :: map() | :unavailable
  def force_stop_all, do: force_stop_all(__MODULE__)

  @spec force_stop_all(GenServer.server()) :: map() | :unavailable
  def force_stop_all(server) do
    if Process.whereis(server),
      do: GenServer.call(server, :force_stop_all, 30_000),
      else: :unavailable
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: Map.get(metadata, :issue_id, issue_id),
          kind: running_entry_kind(metadata),
          profile: Map.get(metadata, :profile),
          label: Map.get(metadata, :label),
          run_id: Map.get(metadata, :run_id),
          identifier: metadata.identifier,
          project_id: Map.get(metadata, :project_id),
          state: running_entry_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now),
          session_history: Map.get(metadata, :session_history, []),
          session_history_total_count:
            Map.get(
              metadata,
              :session_history_total_count,
              length(Map.get(metadata, :session_history, []))
            )
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {_issue_id, metadata} ->
        %{
          issue_id: metadata.issue_id,
          identifier: metadata.identifier,
          state: metadata.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          reason: metadata.reason,
          detail: metadata.detail,
          blocked_at: metadata.blocked_at,
          session_history: Map.get(metadata, :session_history, []),
          session_history_total_count:
            Map.get(
              metadata,
              :session_history_total_count,
              length(Map.get(metadata, :session_history, []))
            )
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       rate_limit_observation: Map.get(state, :codex_rate_limit_observation),
       rate_limit_gate: rate_limit_gate_snapshot(),
       config_error: config_error_payload(state.last_config_error),
       operator_tasks: operator_tasks_payload(state),
       polling: %{
         listening?: listening?(state),
         listening_mode: listening_mode_string(state),
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    if listening?(state) do
      do_handle_request_refresh(state)
    else
      {:reply,
       %{
         queued: false,
         coalesced: true,
         requested_at: DateTime.utc_now(),
         operations: [],
         listening?: listening?(state),
         listening_mode: listening_mode_string(state)
       }, state}
    end
  end

  def handle_call(:start_listening, _from, state) do
    case runtime_config() do
      {:ok, _config} ->
        state = %{state | listening_mode: :listening_all, last_config_error: nil}
        state = schedule_tick(state, 0)
        persist_event("orchestrator.listening_started", nil, %{mode: "listening_all"})
        notify_dashboard()

        reply = %{
          listening?: listening?(state),
          listening_mode: listening_mode_string(state),
          changed_at: DateTime.utc_now()
        }

        {:reply, reply, state}

      {:error, reason} ->
        state =
          log_config_error_once(
            %{state | listening_mode: :not_listening, poll_check_in_progress: false},
            reason
          )

        notify_dashboard()

        reply = %{
          listening?: listening?(state),
          listening_mode: listening_mode_string(state),
          error: inspect(reason),
          changed_at: DateTime.utc_now()
        }

        {:reply, reply, state}
    end
  end

  def handle_call(:start_refine_only_listening, _from, state) do
    case runtime_config() do
      {:ok, _config} ->
        state = %{state | listening_mode: :listening_refine_only, last_config_error: nil}
        state = schedule_tick(state, 0)
        persist_event("orchestrator.listening_started", nil, %{mode: "listening_refine_only"})
        notify_dashboard()

        reply = %{
          listening?: listening?(state),
          listening_mode: listening_mode_string(state),
          changed_at: DateTime.utc_now()
        }

        {:reply, reply, state}

      {:error, reason} ->
        state =
          log_config_error_once(
            %{state | listening_mode: :not_listening, poll_check_in_progress: false},
            reason
          )

        notify_dashboard()

        reply = %{
          listening?: listening?(state),
          listening_mode: listening_mode_string(state),
          error: inspect(reason),
          changed_at: DateTime.utc_now()
        }

        {:reply, reply, state}
    end
  end

  def handle_call(:stop_listening, _from, state) do
    previous_mode = listening_mode_string(state)
    state = %{state | listening_mode: :not_listening, poll_check_in_progress: false}
    persist_event("orchestrator.listening_stopped", nil, %{previous_mode: previous_mode})
    notify_dashboard()

    reply = %{
      listening?: listening?(state),
      listening_mode: listening_mode_string(state),
      changed_at: DateTime.utc_now()
    }

    {:reply, reply, state}
  end

  def handle_call(:force_stop_all, _from, state) do
    {state, rollback_results} =
      state
      |> Map.put(:listening_mode, :not_listening)
      |> clear_operator_tasks(:stopped)
      |> cancel_retry_timers()
      |> force_stop_running_entries()

    cancelled_tasks = cancel_active_worker_tasks()

    persist_event("orchestrator.force_stop_all", nil, %{
      rollback_results: rollback_results,
      cancelled_tasks: cancelled_tasks
    })

    notify_dashboard()

    {:reply,
     %{
       listening?: listening?(state),
       listening_mode: listening_mode_string(state),
       stopped_agents: length(rollback_results),
       cancelled_tasks: cancelled_tasks,
       rollback_results: rollback_results,
       changed_at: DateTime.utc_now()
     }, state}
  end

  def handle_call({:request_operator_task, kind}, _from, state)
      when kind in [:nap, :day_dreaming] do
    handle_operator_task_request(state, kind, nil)
  end

  def handle_call({:request_operator_task, kind, project_id}, _from, state)
      when kind in [:nap, :day_dreaming] do
    handle_operator_task_request(state, kind, project_id)
  end

  defp handle_operator_task_request(state, kind, project_id) do
    {state, task, request_status} = request_operator_task(state, kind, project_id)

    if request_status == :accepted do
      persist_event("operator_task.requested", nil, %{
        kind: to_string(kind),
        project_id: task.project_id,
        status: task.status,
        run_id: task.run_id
      })

      notify_dashboard()
    end

    {:reply, operator_task_reply(task, request_status), state}
  end

  defp do_handle_request_refresh(state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"],
       listening?: listening?(state),
       listening_mode: listening_mode_string(state)
     }, state}
  end

  defp request_operator_task(%State{} = state, kind, project_id) do
    state = reconcile_stale_operator_entries(state)
    current = operator_task(state, kind)

    case current.status do
      :queued ->
        reject_operator_task(state, current, project_id, {:operator_task_already_queued, kind})

      status when status in [:starting, :running] ->
        reject_operator_task(state, current, project_id, {:operator_task_busy, kind})

      _ ->
        {state, task} = request_new_operator_task(state, kind, project_id)
        {state, task, :accepted}
    end
  end

  defp reject_operator_task(state, current, project_id, reason) do
    failure_reason = operator_task_rejection_reason(reason)

    Logger.error(
      "Operator task request rejected action=reject kind=#{current.kind} project_id=#{project_id || "n/a"} " <>
        "active_project_id=#{current.project_id || "n/a"} run_id=#{current.run_id || "n/a"} reason=#{inspect(reason)}"
    )

    rejected = %{
      current
      | status: :failed,
        finished_at: DateTime.utc_now(),
        failure_reason: failure_reason,
        summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
    }

    {state, rejected, :rejected}
  end

  defp operator_task_rejection_reason({:operator_task_busy, kind}),
    do: "operator_task_busy: #{kind} run is already in progress"

  defp operator_task_rejection_reason({:operator_task_already_queued, kind}),
    do: "operator_task_already_queued: #{kind} run is already queued"

  defp request_new_operator_task(state, kind, project_id) do
    case resolve_operator_project(project_id) do
      {:ok, project} ->
        request_operator_task_for_project(state, kind, project)

      {:error, reason} ->
        put_failed_operator_task(state, kind, new_operator_task(kind, project_id), reason)
    end
  end

  defp request_operator_task_for_project(state, kind, project) do
    task = new_operator_task(kind, Map.fetch!(project, :id))

    case load_operator_workflow(project) do
      {:ok, workflow} ->
        Config.with_workflow_context(workflow, fn ->
          queue_or_start_operator_task(state, kind, task)
        end)

      {:error, reason} ->
        put_failed_operator_task(state, kind, task, reason)
    end
  end

  defp queue_or_start_operator_task(state, kind, task) do
    if runtime_busy?(state) or rate_limit_gate_blocked?(state) do
      queued = %{task | status: :queued, queued_at: DateTime.utc_now()}
      {put_operator_task(state, kind, queued), queued}
    else
      {state, started} = start_operator_task(state, task)
      {put_operator_task(state, kind, started), started}
    end
  end

  defp put_failed_operator_task(state, kind, task, reason) do
    failed = fail_operator_task_resolution(task, reason)
    {put_operator_task(state, kind, failed), failed}
  end

  defp maybe_start_queued_operator_tasks(%State{} = state) do
    state = reconcile_stale_operator_entries(state)

    if runtime_busy?(state) do
      state
    else
      Enum.reduce([:nap, :day_dreaming], state, &maybe_start_queued_operator_task/2)
    end
  end

  defp maybe_start_queued_operator_task(kind, state) do
    task = operator_task(state, kind)

    if task.status == :queued do
      {state, started} = start_operator_task(state, task)

      if started.status == :running do
        persist_event("operator_task.started", nil, %{
          kind: to_string(kind),
          run_id: started.run_id
        })
      end

      put_operator_task(state, kind, started)
    else
      state
    end
  end

  defp new_operator_task(kind, project_id) do
    %{
      kind: kind,
      project_id: project_id,
      status: :idle,
      run_id: "operator-#{kind}-#{System.unique_integer([:positive])}",
      requested_at: DateTime.utc_now(),
      queued_at: nil,
      started_at: nil,
      finished_at: nil,
      failure_reason: nil,
      summary: nil
    }
  end

  defp start_operator_task(%State{} = state, task) do
    with {:ok, project} <- resolve_operator_project(task.project_id),
         {:ok, workflow} <- load_operator_workflow(project) do
      Config.with_workflow_context(workflow, fn ->
        maybe_start_operator_task_for_workflow(state, task, workflow)
      end)
    else
      {:error, reason} -> {state, fail_operator_task_resolution(task, reason)}
    end
  end

  defp maybe_start_operator_task_for_workflow(state, task, workflow) do
    if rate_limit_gate_blocked?(state),
      do: {state, task},
      else: do_start_operator_task(state, task, workflow)
  end

  defp do_start_operator_task(%State{} = state, task, workflow) do
    started = %{
      task
      | status: :running,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        failure_reason: nil,
        summary: %{created: 0, skipped: 0, failed: 0, issues: []}
    }

    case persist_operator_run_started(started) do
      {:ok, run} ->
        start_operator_task_after_run(state, started, run, workflow)

      {:error, reason} ->
        failure_reason =
          "run-start persistence failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"

        Logger.error("Operator run-start persistence failed action=fail_task kind=#{task.kind} run_id=#{task.run_id} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")

        failed = %{
          started
          | status: :failed,
            finished_at: DateTime.utc_now(),
            failure_reason: failure_reason,
            summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
        }

        {state, failed}
    end
  end

  defp spawn_operator_task(%State{} = state, task, worker_host, workflow) do
    recipient = self()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           run_operator_task(state, task, recipient, worker_host, workflow)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching operator task to agent: kind=#{task.kind} run_id=#{task.run_id} pid=#{inspect(pid)} worker_host=#{worker_host || "local"}")

        {put_operator_running_entry(state, task, pid, ref, worker_host), task}

      {:error, reason} ->
        fail_operator_task_start(state, task, "failed to spawn operator task: #{inspect(reason)}")
    end
  end

  defp run_operator_task(state, task, recipient, worker_host, workflow) do
    Config.with_workflow_context(workflow, fn ->
      result =
        agent_runner().run_operator(task.kind, task.run_id, recipient,
          project_id: task.project_id,
          worker_host: worker_host,
          run_id: task.run_id,
          rate_limit_snapshot: state.codex_rate_limits,
          rate_limit_settings: Config.settings!()
        )

      send(recipient, {:agent_runner_finished, task.run_id, result})
      result
    end)
  end

  defp fail_operator_task_start(%State{} = state, task, reason) do
    failed = %{
      task
      | status: :failed,
        finished_at: DateTime.utc_now(),
        failure_reason: reason,
        summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: reason}
    }

    running_entry = operator_running_entry(failed, nil, nil, "local")

    persist_event(
      "operator_task.failed",
      nil,
      %{kind: to_string(task.kind), run_id: task.run_id, reason: reason},
      task.run_id
    )

    persist_run_finished(running_entry, "failed", reason)

    {state, failed}
  end

  defp put_operator_running_entry(%State{} = state, task, pid, ref, worker_host) do
    running_entry = operator_running_entry(task, pid, ref, worker_host)
    %{state | running: Map.put(state.running, task.run_id, running_entry)}
  end

  defp operator_running_entry(task, pid, ref, worker_host) do
    identity = AgentRunner.operator_task_identity(task.kind, task.run_id)

    running_entry = %RunningOperator{
      kind: task.kind,
      profile: to_string(task.kind),
      label: identity.label,
      project_id: task.project_id,
      pid: pid,
      ref: ref,
      run_id: task.run_id,
      identifier: identity.identifier,
      issue_id: nil,
      issue: nil,
      state: to_string(task.status),
      worker_host: worker_host,
      workspace_path: nil,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: "operator_task.started",
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: 0,
      started_at: task.started_at,
      session_history: [
        %{
          at: task.started_at,
          source: :system,
          event: "operator_task.started",
          label: identity.label,
          detail: "Operator task started",
          severity: :info
        }
      ],
      session_history_total_count: 1
    }

    running_entry
  end

  defp operator_task_issue(task) do
    identity = AgentRunner.operator_task_identity(task.kind, task.run_id)

    %Issue{
      id: task.run_id,
      identifier: identity.identifier,
      title: identity.label,
      description: identity.description,
      state: identity.label,
      assigned_to_worker: false,
      labels: ["operator", to_string(task.kind)]
    }
  end

  defp operator_task_label(kind), do: AgentRunner.operator_task_identity(kind, nil).label

  defp finish_operator_task(%State{} = state, running_entry, status, failure_reason)
       when status in [:completed, :failed] do
    case operator_kind_from_running_entry(running_entry) do
      nil ->
        state

      kind ->
        now = DateTime.utc_now()

        task =
          state
          |> operator_task(kind)
          |> Map.merge(%{
            status: status,
            run_id: Map.get(running_entry, :run_id),
            finished_at: now,
            failure_reason: failure_reason,
            summary: operator_task_summary(status, failure_reason, Map.get(running_entry, :run_id))
          })

        put_operator_task(state, kind, task)
    end
  end

  defp operator_task_summary(:completed, _failure_reason, run_id),
    do: operator_task_results(run_id)

  defp operator_task_summary(:failed, failure_reason, run_id) do
    run_id
    |> operator_task_results()
    |> Map.update!(:failed, &max(&1, 1))
    |> Map.put(:error, failure_reason)
  end

  defp operator_task_results(run_id) when is_binary(run_id) do
    case PersistenceProvider.read(fn ->
           persistence().list_events(
             run_id: run_id,
             event_type: "linear.tool_call",
             order: :asc,
             limit: 10_000
           )
         end) do
      events when is_list(events) ->
        Results.aggregate(events)

      {:error, reason} ->
        Results.aggregate([])
        |> Map.merge(%{unavailable: true, error: inspect(reason)})
    end
  end

  defp operator_task_results(_run_id), do: Results.aggregate([])

  defp resolve_operator_project(nil), do: resolve_unambiguous_operator_project()
  defp resolve_operator_project(""), do: resolve_unambiguous_operator_project()

  defp resolve_operator_project(project_id) when is_binary(project_id) do
    case enabled_operator_projects() do
      {:ok, projects} ->
        case Enum.find(projects, &(Map.get(&1, :id) == project_id)) do
          nil -> {:error, :unknown_project}
          project -> {:ok, project}
        end

      {:error, reason} ->
        {:error, {:project_lookup_failed, reason}}
    end
  end

  defp resolve_unambiguous_operator_project do
    case enabled_operator_projects() do
      {:ok, [project]} -> {:ok, project}
      {:ok, _projects} -> {:error, :project_required}
      {:error, reason} -> {:error, {:project_lookup_failed, reason}}
    end
  end

  defp enabled_operator_projects do
    case PersistenceProvider.read(fn -> persistence().list_projects() end) do
      projects when is_list(projects) ->
        {:ok, Enum.filter(projects, &(Map.get(&1, :enabled, true) == true))}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_list_projects_result, other}}
    end
  end

  defp load_operator_workflow(project) do
    case persistence().current_workflow(project) do
      nil -> {:error, :no_workflow}
      {:error, reason} -> {:error, {:workflow_lookup_failed, reason}}
      workflow -> {:ok, persistence().workflow_to_loaded(workflow)}
    end
  rescue
    error -> {:error, {:workflow_lookup_failed, error}}
  end

  defp fail_operator_task_resolution(task, reason) do
    failure_reason = operator_project_failure_reason(reason, task.project_id)

    %{
      task
      | status: :failed,
        finished_at: DateTime.utc_now(),
        failure_reason: failure_reason,
        summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
    }
  end

  defp operator_project_failure_reason(:project_required, _project_id), do: "project required"

  defp operator_project_failure_reason(:unknown_project, project_id),
    do: "unknown project: #{project_id}"

  defp operator_project_failure_reason(:no_workflow, project_id),
    do: "no workflow for project: #{project_id}"

  defp operator_project_failure_reason({:project_lookup_failed, reason}, _project_id),
    do: "project lookup failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"

  defp operator_project_failure_reason({:workflow_lookup_failed, reason}, project_id),
    do: "workflow lookup failed for project #{project_id}: #{inspect(reason, limit: 20, printable_limit: 1_000)}"

  defp operator_kind_from_running_entry(%RunningOperator{kind: kind})
       when kind in [:nap, :day_dreaming], do: kind

  defp operator_kind_from_running_entry(_running_entry), do: nil

  defp clear_operator_tasks(%State{} = state, status) do
    tasks =
      state.operator_tasks
      |> Enum.map(fn {kind, task} ->
        {kind,
         %{
           task
           | status: status,
             finished_at: DateTime.utc_now(),
             failure_reason: "force stopped"
         }}
      end)
      |> Map.new()

    %{state | operator_tasks: tasks}
  end

  defp runtime_busy?(%State{} = state),
    do: Enum.any?(state.running, fn {_id, entry} -> runtime_entry_active?(entry) end)

  defp runtime_entry_active?(%RunningIssue{}), do: true

  defp runtime_entry_active?(%RunningOperator{pid: pid, session_id: session_id}) do
    (is_pid(pid) and Process.alive?(pid)) or is_binary(session_id)
  end

  defp runtime_entry_active?(_entry), do: false

  defp issue_running_ids(running) when is_map(running) do
    running
    |> Enum.flat_map(fn
      {id, %RunningIssue{}} -> [id]
      {_id, %RunningOperator{}} -> []
    end)
  end

  defp reconcile_stale_operator_entries(%State{} = state) do
    Enum.reduce(state.running, state, fn {run_id, running_entry}, state_acc ->
      if stale_operator_running_entry?(running_entry) do
        reason = "operator task has no live process or Codex session"

        failed_entry =
          append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
            source: :system,
            run_id: run_id,
            kind: running_entry_kind(running_entry),
            reason: reason
          })

        persist_event(
          "operator_task.stale_failed",
          nil,
          %{kind: running_entry_kind(running_entry), run_id: run_id, reason: reason},
          running_entry.run_id
        )

        persist_run_finished(failed_entry, "failed", reason)

        state_acc
        |> Map.update!(:running, &Map.delete(&1, run_id))
        |> finish_operator_task(failed_entry, :failed, reason)
      else
        state_acc
      end
    end)
  end

  defp stale_operator_running_entry?(%RunningOperator{} = running_entry),
    do: !runtime_entry_active?(running_entry)

  defp stale_operator_running_entry?(_running_entry), do: false

  defp operator_task(%State{} = state, kind) do
    Map.get(state.operator_tasks || %{}, kind, %{
      kind: kind,
      project_id: nil,
      status: :idle,
      run_id: nil,
      requested_at: nil,
      queued_at: nil,
      started_at: nil,
      finished_at: nil,
      failure_reason: nil,
      summary: nil
    })
  end

  defp put_operator_task(%State{} = state, kind, task),
    do: %{state | operator_tasks: Map.put(state.operator_tasks || %{}, kind, task)}

  defp operator_task_reply(task, request_status) do
    task
    |> operator_task_payload()
    |> Map.put(:accepted, request_status == :accepted)
  end

  defp operator_tasks_payload(%State{} = state) do
    %{
      nap: operator_task_payload(operator_task(state, :nap)),
      day_dreaming: operator_task_payload(operator_task(state, :day_dreaming))
    }
  end

  defp operator_task_payload(task) do
    %{
      kind: to_string(task.kind),
      project_id: task.project_id,
      status: to_string(task.status),
      run_id: task.run_id,
      requested_at: iso8601_or_nil(task.requested_at),
      queued_at: iso8601_or_nil(task.queued_at),
      started_at: iso8601_or_nil(task.started_at),
      finished_at: iso8601_or_nil(task.finished_at),
      failure_reason: task.failure_reason,
      summary: task.summary
    }
  end

  defp iso8601_or_nil(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_nil(_value), do: nil

  defp cancel_retry_timers(%State{retry_attempts: retry_attempts} = state) do
    Enum.each(retry_attempts, fn
      {_issue_id, %{timer_ref: timer_ref}} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)

      _ ->
        :ok
    end)

    %{state | retry_attempts: %{}}
  end

  defp force_stop_running_entries(%State{running: running} = state) do
    {state, results} =
      Enum.reduce(running, {state, []}, fn {issue_id, running_entry}, {state_acc, results_acc} ->
        result = rollback_running_entry(issue_id, running_entry)
        state_acc = terminate_running_issue(state_acc, issue_id, false)
        {state_acc, [result | results_acc]}
      end)

    {%{state | running: %{}, claimed: MapSet.new()}, Enum.reverse(results)}
  end

  defp rollback_running_entry(_run_id, %RunningOperator{} = running_entry) do
    kind = running_entry_kind(running_entry)
    persist_event("run.force_stopped", nil, %{run_id: running_entry.run_id, kind: kind})
    %{run_id: running_entry.run_id, kind: kind, status: "stopped", reason: "operator_task"}
  end

  defp rollback_running_entry(issue_id, %RunningIssue{} = running_entry),
    do: rollback_issue_running_entry(issue_id, running_entry)

  defp rollback_issue_running_entry(issue_id, running_entry) do
    transitions = Map.get(running_entry, :linear_state_transitions, [])

    result =
      transitions
      |> Enum.find(&Map.get(&1, :rollback_to_state))
      |> rollback_transition(issue_id, running_entry)

    persist_event("run.force_stopped", Map.get(running_entry, :identifier), %{
      issue_id: issue_id,
      rollback: result
    })

    result
  end

  defp rollback_transition(nil, issue_id, running_entry) do
    %{
      issue_id: issue_id,
      issue_identifier: Map.get(running_entry, :identifier),
      status: "skipped",
      reason: "no_symphony_owned_transition"
    }
  end

  defp rollback_transition(transition, issue_id, running_entry) do
    expected_state = Map.get(transition, :to_state)
    rollback_to_state = Map.get(transition, :rollback_to_state)
    identifier = Map.get(running_entry, :identifier)

    with {:ok, [%Issue{state: current_state} | _]} <-
           Tracker.fetch_issue_states_by_ids([issue_id]),
         true <- normalize_issue_state(current_state) == normalize_issue_state(expected_state),
         :ok <- Tracker.update_issue_state(issue_id, rollback_to_state) do
      %{
        issue_id: issue_id,
        issue_identifier: identifier,
        status: "rolled_back",
        from_state: expected_state,
        to_state: rollback_to_state
      }
    else
      false ->
        %{
          issue_id: issue_id,
          issue_identifier: identifier,
          status: "skipped",
          reason: "linear_state_changed",
          expected_state: expected_state
        }

      {:ok, []} ->
        %{
          issue_id: issue_id,
          issue_identifier: identifier,
          status: "skipped",
          reason: "issue_not_found"
        }

      {:error, reason} ->
        %{
          issue_id: issue_id,
          issue_identifier: identifier,
          status: "failed",
          reason: inspect(reason)
        }
    end
  end

  defp cancel_active_worker_tasks do
    persistence = PersistenceProvider.module()

    case PersistenceProvider.read(fn -> persistence.list_tasks(limit: 1_000) end) do
      tasks when is_list(tasks) ->
        tasks
        |> Enum.filter(&(Map.get(&1, :status) in ["queued", "leased", "running"]))
        |> Enum.reduce({0, []}, &accumulate_task_cancellation(&1, persistence, &2))
        |> then(fn {cancelled, failed} ->
          cancellation_result(cancelled, Enum.reverse(failed))
        end)

      {:error, reason} ->
        cancellation_result(0, [%{task_id: nil, reason: inspect(reason)}])

      other ->
        cancellation_result(0, [%{task_id: nil, reason: inspect({:unexpected_result, other})}])
    end
  end

  defp accumulate_task_cancellation(task, persistence, {cancelled, failed}) do
    task_id = Map.get(task, :id)

    case cancel_worker_task(persistence, task_id) do
      :ok -> {cancelled + 1, failed}
      {:error, reason} -> {cancelled, [%{task_id: task_id, reason: reason} | failed]}
    end
  end

  defp cancel_worker_task(persistence, task_id) do
    case persistence.cancel_task(task_id, "force_stop_all") do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, inspect({:unexpected_result, other})}
    end
  rescue
    error -> {:error, inspect(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp cancellation_result(cancelled, failed) do
    status =
      cond do
        failed == [] -> :ok
        cancelled == 0 -> :error
        true -> :partial
      end

    %{cancelled: cancelled, failed: failed, status: status}
  end

  defp integrate_codex_update(running_entry, %{event: _event, timestamp: _timestamp} = update) do
    SessionHistory.integrate_codex_update(running_entry, update)
  end

  defp initial_session_history(%Issue{} = issue, attempt, worker_host) do
    SessionHistory.initial(issue, attempt, worker_host)
  end

  defp append_system_history(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    SessionHistory.append_system(running_entry, update)
  end

  defp append_session_history(running_entry, event, label, metadata) when is_map(running_entry) do
    SessionHistory.append(running_entry, event, label, metadata)
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    case runtime_config() do
      {:ok, config} ->
        %{
          state
          | poll_interval_ms: config.polling.interval_ms,
            max_concurrent_agents: Config.panel_max_concurrent_agents(),
            last_config_error: nil
        }

      {:error, reason} ->
        state
        |> log_config_error_once(reason)
        |> Map.merge(%{
          listening_mode: :not_listening,
          poll_check_in_progress: false,
          max_concurrent_agents: 0
        })
    end
  end

  defp listening?(%State{listening_mode: :not_listening}), do: false
  defp listening?(%State{}), do: true

  defp listening_mode_string(%State{listening_mode: mode}) when is_atom(mode),
    do: Atom.to_string(mode)

  defp listening_mode_atom(%State{listening_mode: mode}), do: mode

  defp runtime_config do
    case Config.settings() do
      {:error, :missing_project_context} -> aggregate_runtime_limits(WorkflowStore.list_enabled())
      result -> result
    end
  end

  defp aggregate_runtime_limits(workflows) do
    with true <- workflows != [] || {:error, :setup_required},
         {:ok, settings} <- parse_runtime_settings(workflows) do
      {:ok,
       %{
         polling: %{interval_ms: settings |> Enum.map(& &1.polling.interval_ms) |> Enum.min()},
         agent: %{}
       }}
    end
  end

  defp parse_runtime_settings(workflows) do
    Enum.reduce_while(workflows, {:ok, []}, &parse_runtime_setting/2)
  end

  defp parse_runtime_setting(%{config: config}, {:ok, settings}) do
    with {:ok, parsed} <- Schema.parse(config),
         :ok <- Config.validate_settings(parsed) do
      {:cont, {:ok, [parsed | settings]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp agent_runner do
    Application.get_env(:symphony_elixir, :agent_runner_module, AgentRunner)
  end

  defp rate_limit_gate_allows_dispatch(%State{} = state) do
    case check_rate_limit_gate(state) do
      :allow -> :allow
      {:block, details} -> {:block, details}
    end
  end

  defp refresh_rate_limit_gate(%State{} = state) do
    case check_rate_limit_gate(state) do
      :allow ->
        %{
          state
          | rate_limit_gate: rate_limit_gate_allow_snapshot(),
            rate_limit_gate_event_fingerprint: nil
        }

      {:block, details} ->
        apply_rate_limit_gate_block(state, details)
    end
  end

  defp apply_rate_limit_gate_block(%State{} = state, details) when is_map(details) do
    fingerprint = rate_limit_gate_fingerprint(details)

    if state.rate_limit_gate_event_fingerprint != fingerprint do
      persist_event(
        "codex.rate_limit_gate.blocked",
        nil,
        Map.put(details, :message, rate_limit_gate_message(details))
      )
    end

    %{state | rate_limit_gate: details, rate_limit_gate_event_fingerprint: fingerprint}
  end

  defp rate_limit_gate_blocked?(%State{} = state) do
    case check_rate_limit_gate(state) do
      {:block, _details} -> true
      _ -> false
    end
  end

  defp rate_limit_gate_snapshot do
    %{status: :project_scoped, reason: :project_scoped}
  end

  defp check_rate_limit_gate(%State{} = state) do
    RateLimitGate.check(state.codex_rate_limits, Config.settings!())
  rescue
    error ->
      reason = Exception.message(error)

      Logger.error("Rate-limit gate evaluation failed action=block_dispatch status=blocked reason=#{inspect(reason)}")

      {:block, %{status: :blocked, reason: :evaluation_error, error: reason}}
  end

  defp rate_limit_gate_allow_snapshot do
    %{
      status: :allow,
      reason: :available
    }
  end

  defp rate_limit_gate_fingerprint(details) do
    [
      Map.get(details, :window),
      Map.get(details, :window_duration_mins),
      Map.get(details, :threshold_percent),
      Map.get(details, :resets_at),
      Map.get(details, :resume_after)
    ]
  end

  defp rate_limit_gate_message(%{reason: :evaluation_error, error: error}) do
    "Codex session start paused because rate-limit gate evaluation failed: #{error}"
  end

  defp rate_limit_gate_message(details) do
    "Codex session start paused by #{Map.get(details, :window)} rate-limit headroom: remaining=#{Map.get(details, :remaining_percent)} threshold=#{Map.get(details, :threshold_percent)} resume_after=#{Map.get(details, :resume_after) || "n/a"}"
  end

  defp config_error_payload(nil), do: nil

  defp config_error_payload(reason) do
    %{
      reason: inspect(reason),
      message: config_validation_error_message(reason),
      unavailable: database_read_error?(reason)
    }
  end

  defp database_read_error?(:repo_unavailable), do: true
  defp database_read_error?({:query_failed, _reason}), do: true
  defp database_read_error?(_reason), do: false

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    DispatchPolicy.dispatch_slots_available?(issue, state, dispatch_policy_settings(state))
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update, project_id) when is_map(update) do
    case Update.rate_limits(update) do
      %{} = rate_limits ->
        state = %{
          state
          | codex_rate_limits: rate_limits,
            codex_rate_limit_observation: %{status: :parsed, at: DateTime.utc_now()}
        }

        refresh_project_rate_limit_gate(state, project_id)

      _ ->
        if Update.rate_limit_update_event?(update) do
          %{
            state
            | codex_rate_limit_observation: %{
                status: :unrecognized,
                at: DateTime.utc_now(),
                event: Map.get(update, :event),
                debug_payload: Update.rate_limit_debug_payload(update)
              }
          }
        else
          state
        end
    end
  end

  defp apply_codex_rate_limits(state, _update, _project_id), do: state

  defp refresh_project_rate_limit_gate(state, project_id) do
    {:ok, workflow} = WorkflowStore.for_project(project_id)
    Config.with_workflow_context(workflow, fn -> refresh_rate_limit_gate(state) end)
  end

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp running_entry_state(%{issue: %{state: state}}), do: state
  defp running_entry_state(metadata), do: Map.get(metadata, :state, "running")

  defp running_entry_kind(%RunningIssue{kind: kind}), do: Atom.to_string(kind)
  defp running_entry_kind(%RunningOperator{kind: kind}), do: Atom.to_string(kind)

  defp persist_polled_issues(issues) do
    if persistence_enabled?() do
      project_id = Map.get(current_workflow_context(), :project_id)

      Enum.each(issues, &persist_polled_issue(&1, project_id))
    end

    :ok
  end

  defp persist_polled_issue(%Issue{} = issue, project_id) do
    case persist_write(:upsert_polled_issue, persistence_context(issue), fn ->
           persistence().upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id))
         end) do
      {:ok, _issue_record} -> :ok
      {:degraded, :repo_unavailable} -> :ok
    end
  end

  defp persist_polled_issue(_issue, _project_id), do: :ok

  # The workflow context is set by Config.with_workflow_context/2 while the
  # orchestrator iterates enabled projects. Defaults keep single-project
  # behavior intact when no context is active (e.g. operator tasks).
  defp current_workflow_context do
    {:ok, workflow} = Config.current_workflow()
    workflow
  end

  defp current_workflow_record(%{project_id: project_id}) when is_binary(project_id) do
    case Enum.find(persistence().list_projects(), &(&1.id == project_id)) do
      nil -> nil
      project -> persistence().current_workflow(project)
    end
  end

  defp current_workflow_record(_workflow), do: persistence().current_workflow()

  defp persist_run_started_event(issue, run, worker_host) do
    case persist_event(Events.run_started_event(issue, run, worker_host)) do
      :ok -> {:ok, run}
      {:degraded, :repo_unavailable} -> {:ok, run}
    end
  end

  defp persist_operator_started_event(task, run) do
    case persist_event("operator_task.started", nil, %{kind: to_string(task.kind), run_id: run.id}) do
      :ok -> {:ok, run}
      {:degraded, :repo_unavailable} -> {:ok, run}
    end
  end

  defp persist_run_started(%Issue{} = issue, attempt, worker_host) do
    if persistence_enabled?() do
      run_started_persist(issue, attempt, worker_host)
    else
      {:ok, nil}
    end
  rescue
    error ->
      context = persistence_context(issue)
      log_persistence_failure(:start_run, "fail_task", context, error)
      {:error, {:start_run, {:exception, error}}}
  end

  defp run_started_persist(issue, attempt, worker_host) do
    workflow = current_workflow_context()
    project_id = Map.get(workflow, :project_id)
    context = persistence_context(issue)

    with {:ok, issue_record} <- persist_upsert_issue(context, issue, project_id),
         workflow_record = current_workflow_record(workflow),
         run_attrs =
           issue
           |> Events.run_attrs(workflow_record, "centralized", attempt)
           |> Map.put(:issue_id, issue_record.id)
           |> Map.put_new(:project_id, project_id),
         {:ok, run} <- persist_create_run(context, run_attrs) do
      persist_run_started_event(issue, run, worker_host)
    end
  end

  defp persist_upsert_issue(context, issue, project_id) do
    required_persistence_write(:upsert_issue, context, fn -> upsert_issue!(issue, project_id) end)
  end

  defp persist_create_run(context, run_attrs) do
    required_persistence_write(:create_run, context, fn -> create_run!(run_attrs) end)
  end

  defp upsert_issue!(issue, project_id) do
    persistence().upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id))
  end

  defp create_run!(run_attrs) do
    persistence().create_run(run_attrs)
  end

  defp persist_operator_run_started(task) do
    if persistence_enabled?() do
      operator_run_started_persist(task)
    else
      {:ok, nil}
    end
  rescue
    error ->
      context = %{issue_id: nil, issue_identifier: nil, run_id: task.run_id, session_id: nil}
      log_persistence_failure(:start_operator_run, "fail_task", context, error)
      {:error, {:start_operator_run, {:exception, error}}}
  end

  defp operator_run_started_persist(task) do
    workflow_record = current_workflow_record(current_workflow_context())
    context = %{issue_id: nil, issue_identifier: nil, run_id: task.run_id, session_id: nil}

    with {:ok, run} <- persist_create_operator_run(context, task, workflow_record) do
      persist_operator_started_event(task, run)
    end
  end

  defp persist_create_operator_run(context, task, workflow_record) do
    required_persistence_write(:create_operator_run, context, fn ->
      create_operator_run!(task, workflow_record)
    end)
  end

  defp create_operator_run!(task, _workflow_record) do
    persistence().create_run(%{
      kind: to_string(task.kind),
      profile: to_string(task.kind),
      label: operator_task_label(task.kind),
      project_id: task.project_id,
      status: "running",
      execution_mode: "centralized",
      attempt: 0,
      started_at: task.started_at
    })
  end

  defp persist_worker_task_queued(%Issue{} = issue, attempt) do
    if !persistence_enabled?(), do: throw(:persistence_disabled)

    workflow = current_workflow_context()
    project_id = Map.get(workflow, :project_id)

    {:ok, issue_record} =
      persistence().upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id))

    workflow_record = current_workflow_record(workflow)

    profile = Config.workflow_profile_for_state(issue.state)

    prompt =
      PromptBuilder.build_prompt(issue,
        profile: profile,
        profile_policy: Config.workflow_profile(profile),
        allowed_updates: Config.workflow_allowed_updates(profile),
        attempt: attempt
      )

    run_attrs =
      issue
      |> Events.run_attrs(workflow_record, "worker", attempt)
      |> Map.put(:issue_id, issue_record.id)
      |> Map.put_new(:project_id, project_id)

    {:ok, run} = persistence().create_run(run_attrs)

    {:ok, task} =
      persistence().enqueue_task(
        Events.worker_task_attrs(
          issue,
          run,
          workflow_record,
          prompt,
          profile
        )
      )

    persist_event(Events.task_queued_event(issue, run, task))
    {:ok, %{run: run, task: task}}
  rescue
    error -> {:error, error}
  catch
    :persistence_disabled -> {:error, :persistence_disabled}
  end

  defp persist_run_finished(running_entry, status, failure_reason) when is_map(running_entry) do
    if persistence_enabled?() do
      run_id = Map.get(running_entry, :run_id)
      context = persistence_context(running_entry)

      case RunLifecycle.finish_run(persistence(), run_id, status, failure_reason) do
        {:ok, _run} ->
          persist_event(Events.run_finished_event(running_entry, status, failure_reason))

        :noop ->
          :ok

        {:error, :repo_unavailable} ->
          log_persistence_degraded(:finish_run, context)
          {:degraded, :repo_unavailable}

        {:error, reason} ->
          propagate_persistence_failure(:finish_run, context, reason)
      end
    else
      :ok
    end
  end

  defp persist_workspace_update(running_entry) when is_map(running_entry) do
    if persistence_enabled?(), do: record_workspace_update(running_entry), else: :ok
  end

  defp record_workspace_update(running_entry) do
    case Events.workspace_attrs(running_entry) do
      %{} = attrs -> write_workspace_record(running_entry, attrs)
      _ -> :ok
    end
  end

  defp write_workspace_record(running_entry, attrs) do
    case persist_write(:record_workspace, persistence_context(running_entry), fn ->
           persistence().record_workspace(attrs)
         end) do
      {:ok, _workspace} ->
        persist_event(Events.workspace_created_event(running_entry))

      {:degraded, :repo_unavailable} = degraded ->
        degraded
    end
  end

  defp persist_codex_update(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    persist_event(
      "codex.update",
      Map.get(running_entry, :identifier),
      Update.event_payload(update),
      Map.get(running_entry, :run_id)
    )
  end

  defp persist_event(event_type, issue_identifier, payload, run_id \\ nil) do
    persist_event(Events.event_attrs(event_type, issue_identifier, payload, run_id))
  end

  defp persist_event(%{} = attrs) do
    if persistence_enabled?() do
      record_event(attrs)
    else
      :ok
    end
  end

  defp record_event(attrs) do
    case persist_write(:record_event, persistence_context(attrs), fn ->
           persistence().record_event(attrs)
         end) do
      {:ok, _event} -> :ok
      {:degraded, :repo_unavailable} = degraded -> degraded
    end
  end

  defp required_persistence_write(operation, context, fun) when is_function(fun, 0) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error, __STACKTRACE__}
      end

    case result do
      {:ok, record} ->
        {:ok, record}

      {:error, reason} ->
        log_persistence_failure(operation, "fail_task", context, reason)
        {:error, {operation, reason}}

      {:raised, error, stacktrace} ->
        log_persistence_failure(operation, "fail_task", context, error)
        {:error, {operation, {:exception, error, stacktrace}}}

      other ->
        reason = {:unexpected_result, other}
        log_persistence_failure(operation, "fail_task", context, reason)
        {:error, {operation, reason}}
    end
  end

  defp persist_write(operation, context, fun) when is_function(fun, 0) do
    result =
      try do
        fun.()
      rescue
        error ->
          log_persistence_failure(operation, "propagate", context, error)
          reraise error, __STACKTRACE__
      end

    case result do
      {:ok, record} ->
        {:ok, record}

      {:error, :repo_unavailable} ->
        log_persistence_degraded(operation, context)
        {:degraded, :repo_unavailable}

      {:error, reason} ->
        propagate_persistence_failure(operation, context, reason)

      other ->
        propagate_persistence_failure(operation, context, {:unexpected_result, other})
    end
  end

  defp propagate_persistence_failure(operation, context, reason) do
    log_persistence_failure(operation, "propagate", context, reason)
    :erlang.error({:orchestrator_persistence_failure, operation, reason})
  end

  defp log_persistence_degraded(operation, context) do
    Logger.warning("Orchestrator persistence degraded operation=#{operation} action=continue_degraded #{persistence_log_context(context)} reason=repo_unavailable")
  end

  defp log_persistence_failure(operation, action, context, reason) do
    Logger.error("Orchestrator persistence failed operation=#{operation} action=#{action} #{persistence_log_context(context)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
  end

  defp persistence_log_context(context) do
    "issue_id=#{log_field(Map.get(context, :issue_id))} issue_identifier=#{log_field(Map.get(context, :issue_identifier))} session_id=#{log_field(Map.get(context, :session_id))} run_id=#{log_field(Map.get(context, :run_id))}"
  end

  defp persistence_context(%Issue{} = issue) do
    %{issue_id: issue.id, issue_identifier: issue.identifier, session_id: nil, run_id: nil}
  end

  defp persistence_context(%{event_type: _event_type} = attrs) do
    payload = Map.get(attrs, :payload, %{})

    %{
      issue_id: Payload.get_any(payload, [:issue_id, "issue_id"], nil),
      issue_identifier: Map.get(attrs, :issue_identifier),
      session_id: Payload.get_any(payload, [:session_id, "session_id"], nil),
      run_id: Map.get(attrs, :run_id)
    }
  end

  defp persistence_context(running_entry) when is_map(running_entry) do
    issue = Map.get(running_entry, :issue)

    %{
      issue_id: Map.get(running_entry, :issue_id) || if(is_map(issue), do: Map.get(issue, :id)),
      issue_identifier: Map.get(running_entry, :identifier),
      session_id: Map.get(running_entry, :session_id),
      run_id: Map.get(running_entry, :run_id)
    }
  end

  defp log_field(nil), do: "n/a"
  defp log_field(value), do: inspect(value, limit: 5, printable_limit: 200)

  defp persistence, do: PersistenceProvider.module()

  defp persistence_enabled? do
    Process.whereis(__MODULE__) == self()
  end
end

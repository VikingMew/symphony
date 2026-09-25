# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Worker.AssignmentManager.Sections.Assignment do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      require Logger

      alias SymphonyElixir.{
        Config,
        EnvironmentFailureCircuit,
        Orchestrator,
        PersistenceProvider,
        PromptBuilder,
        RunLifecycle,
        Tracker,
        WorkerResult,
        WorkflowStore
      }

      alias SymphonyElixir.AgentRunner.Policy
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator.{DispatchPolicy, Events}
      alias SymphonyElixir.Worker.HeartbeatHistory

      defp create_run(persistence, issue, workflow, issue_id, project_id, started_at) do
        attrs =
          issue
          |> Events.run_attrs(workflow, "worker", nil)
          |> Map.merge(%{
            issue_id: issue_id,
            project_id: project_id,
            status: "running",
            started_at: started_at
          })

        persistence.create_run(attrs)
      end

      defp move_to_worker_started(tracker, %Issue{} = issue, profile) do
        with {:ok, started_state} <- Policy.worker_started_state(profile) do
          maybe_transition_to_worker_started(tracker, issue, profile, started_state)
        end
      end

      defp maybe_transition_to_worker_started(tracker, %Issue{} = issue, profile, started_state) do
        if same_issue_state?(issue.state, started_state) do
          {:ok, %{issue | state: started_state}}
        else
          transition_to_worker_started(tracker, issue, profile, started_state)
        end
      end

      defp transition_to_worker_started(tracker, %Issue{} = issue, profile, started_state) do
        transitions = Config.settings!().workflow |> Map.get("allowed_transitions", [])

        with :ok <- Policy.validate_worker_start_transition(transitions, issue.state, profile),
             :ok <- tracker.update_issue_state(issue.id, started_state) do
          {:ok, %{issue | state: started_state}}
        end
      end

      defp build_assignment(id, issue, run, worker, session, workflow, opts) do
        payload =
          Events.worker_assignment_payload(issue, run, workflow, opts[:prompt], opts[:profile]).payload

        correlation = %{
          "project_id" => run.project_id,
          "run_id" => run.id,
          "issue_id" => issue.id,
          "issue_identifier" => issue.identifier,
          "run_attempt" => run.attempt,
          "task_id" => id,
          "lease_id" => id,
          "lease_attempt" => 1,
          "worker_id" => worker.id,
          "worker_session_id" => session.id,
          "assignment_id" => id
        }

        %{
          id: id,
          task_id: id,
          lease_id: id,
          issue: issue,
          issue_identifier: issue.identifier,
          project_id: run.project_id,
          run_id: run.id,
          worker_id: worker.id,
          worker_name: Map.get(worker, :name),
          session_id: session.id,
          started_at: Map.get(run, :started_at),
          expires_at: opts[:expires_at],
          payload: payload,
          correlation: correlation
        }
      end

      defp worker_started_state?(state) when is_binary(state) do
        started_states = Policy.worker_started_states() |> DispatchPolicy.normalized_state_set()
        MapSet.member?(started_states, SymphonyElixir.StateName.normalize(state))
      end

      defp worker_started_state?(_state) do
        false
      end

      defp same_issue_state?(left, right) when is_binary(left) and is_binary(right) do
        SymphonyElixir.StateName.normalize(left) == SymphonyElixir.StateName.normalize(right)
      end

      defp assignment_heartbeat(nil, _worker_id, _session_id, _active_ids, _state) do
        {nil, %{lease_renewals: [], commands: []}}
      end

      defp assignment_heartbeat(assignment, worker_id, session_id, active_ids, state) do
        if active_heartbeat_assignment?(assignment, worker_id, session_id, active_ids, state) do
          heartbeat_active_assignment(assignment, state)
        else
          {assignment, %{lease_renewals: [], commands: []}}
        end
      end

      defp active_heartbeat_assignment?(assignment, worker_id, session_id, active_ids, state) do
        assignment.worker_id == worker_id and assignment.session_id == session_id and
          DateTime.compare(assignment.expires_at, state.now.()) in [:eq, :gt] and
          assignment.lease_id in active_ids
      end

      defp heartbeat_active_assignment(%{cancellation: _cancellation} = assignment, _state) do
        assignment = mark_cancel_delivered(assignment)
        {assignment, %{lease_renewals: [], commands: [cancel_command(assignment)]}}
      end

      defp heartbeat_active_assignment(assignment, state) do
        expires_at =
          DateTime.add(state.now.(), state.persistence.worker_lease_duration_seconds(), :second)

        renewal = %{lease_id: assignment.lease_id, lease_expires_at: expires_at}
        {%{assignment | expires_at: expires_at}, %{lease_renewals: [renewal], commands: []}}
      end

      defp expire_assignment(%{assignment: nil} = state) do
        state
      end

      defp expire_assignment(state) do
        if DateTime.compare(state.assignment.expires_at, state.now.()) == :lt do
          assignment = state.assignment

          _ = transition_run(state.persistence, assignment.run_id, "task.failed", nil)

          _ =
            persist_event(
              state.persistence,
              assignment,
              "task.failed",
              %{"reason" => "assignment_expired"},
              nil
            )

          notify_worker_terminal(state, assignment, {:failed, "assignment_expired"})
          %{state | assignment: nil}
        else
          state
        end
      end

      defp matching_assignment(nil, _worker_id, _session_id, _id) do
        {:error, :lease_not_active}
      end

      defp matching_assignment(assignment, worker_id, session_id, id) do
        if assignment.id == id and assignment.worker_id == worker_id and
             assignment.session_id == session_id do
          {:ok, assignment}
        else
          {:error, :lease_not_active}
        end
      end

      defp persist_event(persistence, assignment, event_type, payload, summary) do
        event_payload =
          payload
          |> stringify_keys()
          |> Map.put("correlation", assignment.correlation)
          |> maybe_put_summary(summary)

        persistence.record_event(assignment_event(assignment, event_type, event_payload))
      end

      defp assignment_event(assignment, event_type, payload) do
        %{
          project_id: assignment.project_id,
          run_id: assignment.run_id,
          issue_identifier: assignment.issue_identifier,
          event_type: event_type,
          payload: Map.put_new(payload, "correlation", assignment.correlation)
        }
      end

      defp transition_run(persistence, run_id, event_type, summary) do
        attrs = RunLifecycle.run_event_attrs(event_type, DateTime.utc_now())

        attrs =
          if summary do
            Map.put(attrs, :execution_summary, summary)
          else
            attrs
          end

        case {attrs, persistence.get_run(run_id)} do
          {%{}, _run} when map_size(attrs) == 0 ->
            :ok

          {_attrs, nil} ->
            {:error, :run_not_found}

          {attrs, run} ->
            case persistence.update_run(run, attrs) do
              {:ok, _run} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
      end

      defp close_failed_run(persistence, identifier, reason) do
        case persistence.list_runs_for_issue(identifier, limit: 1) do
          [run | _] -> persistence.finish_run(run.id, "failed", inspect(reason))
          _other -> :ok
        end
      end

      defp reconcile_zombies(state) do
        Enum.each(state.workflows.list_enabled(), fn workflow ->
          Config.with_workflow_context(workflow, fn -> reconcile_workflow_zombies(state) end)
        end)

        expire_assignment(state)
      end

      defp reconcile_workflow_zombies(state) do
        case state.tracker.fetch_issues_by_states(["In Progress"]) do
          {:ok, issues} -> Enum.each(issues, &reconcile_zombie(state, &1))
          {:error, _reason} -> :ok
        end
      end

      defp reconcile_zombie(%{assignment: %{issue: %{id: issue_id}}}, %Issue{id: issue_id}) do
        :ok
      end

      defp reconcile_zombie(state, %Issue{} = issue) do
        case state.persistence.list_runs_for_issue(issue.identifier, limit: 1) do
          [run | _] -> maybe_requeue_zombie(state, issue, run)
          _none -> :ok
        end
      end

      defp maybe_requeue_zombie(
             state,
             issue,
             %{status: "running", started_at: %DateTime{} = started_at} = run
           ) do
        cutoff = DateTime.add(state.now.(), -state.persistence.worker_lease_duration_seconds(), :second)

        if DateTime.compare(started_at, cutoff) == :lt do
          with :ok <- state.tracker.update_issue_state(issue.id, "Ready"),
               {:ok, _run} <- state.persistence.finish_run(run.id, "failed", "worker_assignment_lost") do
            state.persistence.record_event(%{
              project_id: run.project_id,
              run_id: run.id,
              issue_identifier: issue.identifier,
              event_type: "task.failed",
              payload: %{"reason" => "panel_restart_or_worker_loss"}
            })
          end
        end
      end

      defp maybe_requeue_zombie(_state, _issue, _run) do
        :ok
      end

      defp schedule_reconciliation(state) do
        Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
      end

      defp available_slots(attrs) do
        map_get(attrs, "available_slots", :available_slots) || 0
      end

      defp total_slots(attrs) do
        map_get(attrs, "total_slots", :total_slots)
      end

      defp worker_session_liveness(state, worker_id, session_id) do
        case Map.get(state.liveness, {worker_id, session_id}) do
          nil ->
            {:error, :worker_session_not_found}

          %{worker: worker, session: session} = entry ->
            if fresh_liveness?(state, entry) do
              {:ok, worker, session}
            else
              {:error, :worker_session_stale}
            end
        end
      end

      defp observe_request_liveness(state, worker_id, session_id, attrs) do
        case Map.get(state.liveness, {worker_id, session_id}) do
          nil -> observe_known_worker_session(state, worker_id, session_id, attrs)
          %{worker: worker, session: session} -> observe_session_liveness(state, worker, session, attrs)
        end
      end

      defp observe_known_worker_session(state, worker_id, session_id, attrs) do
        case state.persistence.worker_session_identity(worker_id, session_id) do
          {:ok, worker, session} -> observe_session_liveness(state, worker, session, attrs)
          {:error, _reason} -> state
        end
      end

      defp observe_session_liveness(state, worker, session, attrs \\ %{}) do
        total_slots = total_slots(attrs) || Map.fetch!(session, :total_slots)
        worker_id = Map.fetch!(worker, :id)
        session_id = Map.fetch!(session, :id)
        session = Map.put(session, :total_slots, total_slots)

        entry = %{
          worker: worker,
          session: session,
          total_slots: total_slots,
          last_seen_at: state.now.()
        }

        put_in(state.liveness[{worker_id, session_id}], entry)
      end

      defp fresh_liveness_capacity(state) do
        state.liveness
        |> Map.values()
        |> Enum.filter(&fresh_liveness?(state, &1))
        |> Enum.sum_by(& &1.total_slots)
      end

      defp fresh_liveness?(state, %{last_seen_at: last_seen_at}) do
        cutoff = DateTime.add(state.now.(), -liveness_timeout_seconds(state), :second)
        DateTime.compare(last_seen_at, cutoff) in [:eq, :gt]
      end

      defp liveness_timeout_seconds(state) do
        state.persistence.worker_heartbeat_interval_seconds() * 3
      end

      defp admission_evidence(reason, listening_mode) do
        %{
          capacity:
            if reason == :assigned do
              1
            else
              0
            end,
          reason: reason,
          listening_mode: listening_mode
        }
      end

      defp blocking_decision_evidence(issue, decision, listening_mode) do
        :blocking_decision
        |> admission_evidence(listening_mode)
        |> Map.merge(%{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          blocking_decision: Map.take(decision, ["decided_at", "reason", "run_id"])
        })
      end

      defp merge_candidate_skip(_current, {:skip, :blocking_decision, evidence}) do
        {:skip, :blocking_decision, evidence}
      end

      defp merge_candidate_skip({:skip, :blocking_decision, _evidence} = current, _next) do
        current
      end

      defp merge_candidate_skip(_current, {:skip, :listening_mode, evidence}) do
        {:skip, :listening_mode, evidence}
      end

      defp merge_empty_evidence(%{reason: :blocking_decision} = evidence, _next_evidence) do
        evidence
      end

      defp merge_empty_evidence(_evidence, %{reason: :blocking_decision} = next_evidence) do
        next_evidence
      end

      defp merge_empty_evidence(%{reason: :listening_mode} = evidence, _next_evidence) do
        evidence
      end

      defp merge_empty_evidence(_evidence, %{reason: :listening_mode} = next_evidence) do
        next_evidence
      end

      defp merge_empty_evidence(evidence, _next_evidence) do
        evidence
      end

      defp log_admission_skip(:blocking_decision, worker_id, session_id, evidence) do
        blocking_reason = get_in(evidence, [:blocking_decision, "reason"])

        Logger.info(
          "event=worker_claim_skip issue_id=#{evidence.issue_id} issue_identifier=#{evidence.issue_identifier} worker_id=#{worker_id} session_id=#{session_id} skip_reason=blocking_decision blocking_reason=#{inspect(blocking_reason)} listening_mode=#{evidence.listening_mode} capacity=#{evidence.capacity}"
        )
      end

      defp log_admission_skip(reason, worker_id, session_id, evidence)
           when reason in [:not_listening, :listening_mode] do
        Logger.info("event=worker_claim_skip worker_id=#{worker_id} session_id=#{session_id} skip_reason=#{reason} listening_mode=#{evidence.listening_mode} capacity=#{evidence.capacity}")
      end

      defp log_admission_skip(_reason, _worker_id, _session_id, _evidence) do
        :ok
      end

      defp environment_failure_circuit_evidence(circuit, listening_mode) do
        :environment_failure_circuit_open
        |> admission_evidence(listening_mode)
        |> Map.put(:failure_fingerprint, circuit.triggering_fingerprint)
      end

      defp record_environment_failure_circuit(state, assignment, "task.completed", _summary) do
        EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
      end

      defp record_environment_failure_circuit(state, assignment, "task.cancelled", _summary) do
        EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
      end

      defp record_environment_failure_circuit(state, assignment, "task.failed", summary) do
        circuit =
          EnvironmentFailureCircuit.record_failure(
            assignment.issue_identifier,
            worker_failure_reason(summary),
            %{issue_id: assignment.issue.id, run_id: assignment.run_id},
            state.failure_circuit
          )

        if circuit.alert do
          state.persistence.record_event(EnvironmentFailureCircuit.alert_event_attrs(circuit, assignment.project_id))
        end
      end

      defp record_environment_failure_circuit(_state, _assignment, _event_type, _summary) do
        :ok
      end

      defp worker_failure_reason(summary) do
        Map.get(summary, "detail") || failed_gate_detail(summary) || Map.fetch!(summary, "reason")
      end

      defp failed_gate_detail(%{"gates" => gates}) do
        Enum.find_value(gates, fn
          %{"status" => "failed", "failure_detail" => detail} when is_binary(detail) -> detail
          _gate -> nil
        end)
      end

      defp failed_gate_detail(_summary) do
        nil
      end

      defp validate_correlation(payload, correlation) do
        validate_correlation_fields(Map.get(payload, "correlation", %{}), correlation)
      end

      defp validate_correlation_fields(supplied, authoritative) do
        Enum.reduce_while(supplied, :ok, fn {key, value}, :ok ->
          if Map.has_key?(authoritative, key) and authoritative[key] != value do
            {:halt, {:error, {:correlation_mismatch, key}}}
          else
            {:cont, :ok}
          end
        end)
      end

      defp stringify_keys(map) do
        Map.new(map, fn {key, value} -> {to_string(key), value} end)
      end

      defp maybe_put_summary(payload, nil) do
        payload
      end

      defp maybe_put_summary(payload, summary) do
        Map.put(payload, "summary", summary)
      end

      defp map_get(map, string_key, atom_key) do
        Map.get(map, string_key) || Map.get(map, atom_key)
      end

      defp process_alive?(server) do
        GenServer.whereis(server) != nil
      end

      defp active_lease_ids(attrs) do
        map_get(attrs, "active_leases", :active_leases) || []
      end

      defp heartbeat_assignment(_worker_id, _session_id, [], _server) do
        {:ok, %{lease_renewals: [], commands: []}}
      end

      defp heartbeat_assignment(worker_id, session_id, active_ids, server) do
        if process_alive?(server) do
          deadline_ms = System.monotonic_time(:millisecond) + @heartbeat_timeout_ms

          try do
            GenServer.call(
              server,
              {:heartbeat, worker_id, session_id, active_ids, deadline_ms},
              @heartbeat_timeout_ms
            )
          catch
            :exit, {:timeout, _call} -> heartbeat_unavailable()
          end
        else
          {:ok, %{lease_renewals: [], commands: []}}
        end
      end

      defp heartbeat_unavailable do
        {:error, {:heartbeat_unavailable, @heartbeat_retry_after_seconds}}
      end

      defp matching_project_assignment(nil, _project_id) do
        :error
      end

      defp matching_project_assignment(assignment, nil) do
        {:ok, assignment}
      end

      defp matching_project_assignment(%{project_id: project_id} = assignment, project_id) do
        {:ok, assignment}
      end

      defp matching_project_assignment(_assignment, _project_id) do
        :error
      end

      defp new_cancellation(reason, project_id, from) do
        ref = make_ref()

        %{
          reason: reason,
          project_id: project_id,
          ref: ref,
          timer: Process.send_after(self(), {:cancel_timeout, ref}, @cancel_timeout_ms),
          waiters: [from],
          delivered?: false
        }
      end

      defp add_cancel_waiter(%{timer: nil} = cancellation, from) do
        ref = make_ref()

        %{
          cancellation
          | ref: ref,
            timer: Process.send_after(self(), {:cancel_timeout, ref}, @cancel_timeout_ms),
            waiters: [from]
        }
      end

      defp add_cancel_waiter(cancellation, from) do
        %{cancellation | waiters: [from | cancellation.waiters]}
      end

      defp mark_cancel_delivered(%{cancellation: cancellation} = assignment) do
        %{assignment | cancellation: %{cancellation | delivered?: true}}
      end

      defp cancel_command(%{id: task_id, cancellation: cancellation}) do
        %{"type" => "cancel_task", "task_id" => task_id, "reason" => cancellation.reason}
      end

      defp complete_pending_cancellation(
             state,
             %{cancellation: cancellation} = assignment,
             "task.cancelled",
             :ok
           ) do
        cancel_timer(cancellation)
        reply_cancel_waiters(cancellation, cancelled_assignment(assignment, cancellation.project_id))
        state
      end

      defp complete_pending_cancellation(
             state,
             %{cancellation: cancellation} = assignment,
             event_type,
             :ok
           )
           when event_type in @terminal_events do
        cancel_timer(cancellation)

        result =
          failed_cancellation(assignment, :worker_terminal_not_cancelled, cancellation.project_id)

        reply_cancel_waiters(cancellation, result)
        state
      end

      defp complete_pending_cancellation(
             state,
             %{cancellation: cancellation} = assignment,
             event_type,
             {:error, reason}
           )
           when event_type in @terminal_events do
        cancel_timer(cancellation)

        result =
          failed_cancellation(assignment, {:terminal_event_failed, reason}, cancellation.project_id)

        reply_cancel_waiters(cancellation, result)
        %{state | assignment: %{assignment | cancellation: %{cancellation | waiters: [], timer: nil}}}
      end

      defp complete_pending_cancellation(state, _assignment, _event_type, _result) do
        state
      end

      defp assignment_after_event(_state, event_type) when event_type in @terminal_events do
        nil
      end

      defp assignment_after_event(state, _event_type) do
        state.assignment
      end

      defp cancel_timer(%{timer: nil}) do
        :ok
      end

      defp cancel_timer(%{timer: timer}) do
        Process.cancel_timer(timer)
      end

      defp reply_cancel_waiters(%{waiters: waiters}, result) do
        Enum.each(waiters, &GenServer.reply(&1, result))
      end

      defp cancellation_timeout_reason(%{delivered?: true}) do
        :worker_termination_timeout
      end

      defp cancellation_timeout_reason(%{delivered?: false}) do
        :worker_cancel_delivery_timeout
      end

      defp no_active_assignment(project_id) do
        %{
          status: "no_active_assignment",
          cancelled: 0,
          failed: [],
          tasks: [],
          project_id: project_id
        }
      end

      defp cancelled_assignment(assignment, project_id) do
        %{
          status: "cancelled",
          cancelled: 1,
          failed: [],
          tasks: [assignment_result(assignment)],
          project_id: project_id
        }
      end

      defp failed_cancellation(assignment, reason, project_id) do
        %{
          status: "failed",
          cancelled: 0,
          failed: [Map.put(assignment_result(assignment), :reason, inspect(reason))],
          tasks: [],
          project_id: project_id
        }
      end

      defp assignment_result(assignment) do
        %{
          assignment_id: assignment.id,
          task_id: assignment.task_id,
          lease_id: assignment.lease_id,
          project_id: assignment.project_id,
          run_id: assignment.run_id,
          issue_id: assignment.issue.id,
          issue_identifier: assignment.issue_identifier,
          worker_id: assignment.worker_id,
          worker_session_id: assignment.session_id
        }
      end

      defp notify_orchestrator(state, assignment, "task.progress", payload, _summary) do
        Orchestrator.worker_task_progress(assignment.issue.id, payload, state.orchestrator)
      end

      defp notify_orchestrator(state, assignment, event_type, _payload, summary)
           when event_type in @terminal_events do
        notify_worker_terminal(state, assignment, WorkerResult.terminal_outcome(event_type, summary))
      end

      defp notify_orchestrator(_state, _assignment, _event_type, _payload, _summary) do
        :ok
      end

      defp notify_worker_terminal(state, assignment, outcome) do
        Orchestrator.worker_task_finished(assignment.issue.id, outcome, state.orchestrator)
      end

      defp event_payload_with_time(payload, event) do
        Map.put(payload, "occurred_at", Map.get(event, :occurred_at))
      end
    end
  end
end

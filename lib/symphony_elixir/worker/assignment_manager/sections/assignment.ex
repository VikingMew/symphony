# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Worker.AssignmentManager.Sections.Assignment do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      require Logger

      alias SymphonyElixir.{
        BlockingDecision,
        Config,
        EnvironmentFailureCircuit,
        Orchestrator,
        PersistenceProvider,
        Redaction,
        RunAdmission,
        RunFailure,
        Tracker,
        WorkerResult,
        WorkflowStore
      }

      alias SymphonyElixir.AgentRunner.Policy
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator.DispatchPolicy
      alias SymphonyElixir.Worker.{ClaimCommit, ClaimStage, EventWriter, HeartbeatHistory}

      defp candidate_admission(%Issue{} = issue, persistence, orchestrator, dispatch_settings, clear_source) do
        listening_mode = DispatchPolicy.listening_mode(dispatch_settings)

        with true <- DispatchPolicy.allowed_by_listening_mode?(issue.state, dispatch_settings),
             :ok <- live_issue_admission(issue, listening_mode),
             {:ok, record, runs} <- admission_history(issue, persistence),
             :ok <-
               check_blocking_decision(
                 record,
                 runs,
                 issue,
                 persistence,
                 orchestrator,
                 listening_mode,
                 clear_source
               ) do
          if dispatchable_from_history?(issue, runs),
            do: :ok,
            else: {:skip, :run_history, admission_evidence(:run_history, listening_mode)}
        else
          false ->
            {:skip, :listening_mode, admission_evidence(:listening_mode, listening_mode)}

          other ->
            other
        end
      end

      defp dispatchable_from_history?(%Issue{} = issue, runs) do
        if worker_started_state?(issue.state) do
          case runs do
            [%{status: status} | _] -> status in ["succeeded", "failed", "cancelled"]
            [] -> false
          end
        else
          true
        end
      end

      defp admission_history(issue, persistence) do
        case persistence.get_issue_by_identifier(issue.identifier) do
          {:error, reason} -> {:error, reason}
          record -> load_admission_runs(record, issue, persistence)
        end
      end

      defp load_admission_runs(record, issue, persistence) do
        if worker_started_state?(issue.state) or match?(%{blocking_decision: %{}}, record) do
          case persistence.list_runs_for_issue(issue.identifier, limit: 1) do
            {:error, reason} -> {:error, reason}
            runs -> {:ok, record, runs}
          end
        else
          {:ok, record, []}
        end
      end

      defp live_issue_admission(%Issue{} = issue, listening_mode) do
        normalized = SymphonyElixir.StateName.normalize(issue.state)
        active = Config.settings!().tracker.active_states |> DispatchPolicy.normalized_state_set()

        cond do
          not MapSet.member?(active, normalized) -> {:skip, :stale, admission_evidence(:stale, listening_mode)}
          issue.blocked_by != [] -> {:skip, :dependency, admission_evidence(:dependency, listening_mode)}
          Config.human_review_state?(issue.state) -> {:skip, :human_review, admission_evidence(:human_review, listening_mode)}
          true -> :ok
        end
      end

      defp blocking_decision_admission(issue, persistence, orchestrator, listening_mode, clear_source) do
        with {:ok, record, runs} <- admission_history(issue, persistence) do
          check_blocking_decision(record, runs, issue, persistence, orchestrator, listening_mode, clear_source)
        end
      end

      defp check_blocking_decision(%{blocking_decision: %{} = decision}, runs, issue, persistence, orchestrator, listening_mode, clear_source) do
        latest_run_id =
          case runs do
            [%{id: id} | _] -> id
            [] -> nil
          end

        decision
        |> BlockingDecision.validity(issue.state, latest_run_id)
        |> apply_blocking_decision_validity(issue, decision, persistence, orchestrator, listening_mode, clear_source)
      end

      defp check_blocking_decision(_record, _runs, _issue, _persistence, _orchestrator, _listening_mode, _clear_source), do: :ok

      defp apply_blocking_decision_validity(
             :valid,
             issue,
             decision,
             _persistence,
             _orchestrator,
             listening_mode,
             _clear_source
           ) do
        {:skip, :blocking_decision, blocking_decision_evidence(issue, decision, listening_mode)}
      end

      defp apply_blocking_decision_validity(
             {:stale, cause},
             issue,
             decision,
             persistence,
             orchestrator,
             listening_mode,
             clear_source
           ) do
        clear_stale_blocking_decision(
          issue,
          decision,
          clear_source,
          cause,
          persistence,
          orchestrator,
          listening_mode
        )
      end

      defp clear_stale_blocking_decision(
             issue,
             decision,
             source,
             cause,
             persistence,
             orchestrator,
             listening_mode
           ) do
        case BlockingDecision.clear_stale(
               issue.identifier,
               decision,
               source,
               cause,
               persistence
             ) do
          {:ok, _event} ->
            Orchestrator.blocking_decision_cleared(
              issue.id,
              decision["run_id"],
              orchestrator
            )

            Logger.info(
              "event=blocking_decision_cleared issue_id=#{issue.id} issue_identifier=#{issue.identifier} clear_source=#{source} clear_cause=#{cause} blocking_reason=#{inspect(decision["reason"])} origin_state=#{inspect(decision["origin_state"])} run_id=#{inspect(decision["run_id"])} decided_at=#{inspect(decision["decided_at"])}"
            )

            :ok

          :replaced ->
            blocking_decision_admission(
              issue,
              persistence,
              orchestrator,
              listening_mode,
              source
            )

          {:error, reason} ->
            {:error, {:blocking_decision_clear_failed, reason}}
        end
      end

      defp revalidate(%Issue{id: issue_id} = candidate, state, dispatch_settings) do
        context = Map.put(state.claim_context, :issue, candidate)

        result =
          ClaimStage.measure(context, :issue_revalidation, fn ->
            state.tracker.fetch_issue_states_by_ids([issue_id])
          end)

        case result do
          {:ok, [%Issue{} = issue | _]} ->
            revalidate_history(issue, state, dispatch_settings, context)

          {:ok, []} ->
            {:skip, :missing, admission_evidence(:missing, DispatchPolicy.listening_mode(dispatch_settings))}

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp revalidate_history(issue, state, dispatch_settings, context) do
        result =
          ClaimStage.measure(context, :revalidation_history, fn ->
            candidate_admission(issue, state.persistence, state.orchestrator, dispatch_settings, "tracker_revalidation")
          end)

        case result do
          :ok -> {:ok, issue}
          other -> other
        end
      end

      defp prepare_assignment(state, worker, session, workflow, issue) do
        context = Map.put(state.claim_context, :issue, issue)

        ClaimStage.measure(context, :execution_admission, fn ->
          with {:ok, admission} <- state.run_admission.resolve(workflow, {:issue, issue}, %{workspace_authority: {:http_worker, worker.id, session.id}, readiness: :ready}) do
            {:ok, %{workflow: workflow, issue: issue, admission: admission, worker: worker, session: session, profile: Config.workflow_profile_for_state(issue.state)}}
          end
        end)
      end

      defp worker_started_state?(state) when is_binary(state) do
        started_states = Policy.worker_started_states() |> DispatchPolicy.normalized_state_set()
        MapSet.member?(started_states, SymphonyElixir.StateName.normalize(state))
      end

      defp worker_started_state?(_state), do: false

      defp assignment_heartbeat(nil, _worker_id, _session_id, _active_ids, _state),
        do: {nil, %{lease_renewals: [], commands: []}}

      defp assignment_heartbeat(assignment, worker_id, session_id, active_ids, state) do
        if active_heartbeat_assignment?(assignment, worker_id, session_id, active_ids, state) do
          heartbeat_active_assignment(assignment, state)
        else
          {assignment, %{lease_renewals: [], commands: []}}
        end
      end

      defp active_heartbeat_assignment?(assignment, worker_id, session_id, active_ids, state) do
        assignment.worker_id == worker_id and assignment.session_id == session_id and
          DateTime.compare(assignment.expires_at, state.now.()) in [:eq, :gt] and assignment.lease_id in active_ids
      end

      defp heartbeat_active_assignment(%{cancellation: _cancellation} = assignment, _state) do
        assignment = mark_cancel_delivered(assignment)
        {assignment, %{lease_renewals: [], commands: [cancel_command(assignment)]}}
      end

      defp heartbeat_active_assignment(assignment, state) do
        expires_at = DateTime.add(state.now.(), state.persistence.worker_lease_duration_seconds(), :second)
        renewal = %{lease_id: assignment.lease_id, lease_expires_at: expires_at}
        {%{assignment | expires_at: expires_at}, %{lease_renewals: [renewal], commands: []}}
      end

      defp expire_assignment(%{assignment: nil} = state), do: state
      defp expire_assignment(%{event_task: %{}} = state), do: state

      defp expire_assignment(state) do
        if DateTime.compare(state.assignment.expires_at, state.now.()) == :lt do
          assignment = Map.put_new_lazy(state.assignment, :expiry_event_id, &Ecto.UUID.generate/0)
          failure = assignment_expiry_failure(assignment)

          request = %{
            id: assignment.expiry_event_id,
            worker_id: assignment.worker_id,
            session_id: assignment.session_id,
            assignment_id: assignment.id,
            event_type: "task.failed",
            payload: %{"reason" => "assignment_expired"},
            summary: nil,
            terminal: failure
          }

          start_event_write(%{state | assignment: assignment}, request, {:ok, assignment}, nil, :expiry)
        else
          state
        end
      end

      defp assignment_expiry_failure(%{last_terminal_rejection: nil}) do
        RunFailure.classify({:assignment_loss, %{reason: "assignment_expired", phase: "lease"}})
      end

      defp assignment_expiry_failure(%{last_terminal_rejection: rejection}) do
        RunFailure.classify({:assignment_expired, Map.put(rejection, "phase", "lease")})
      end

      defp remember_terminal_rejection(state, assignment, event_type, payload, {:invalid_worker_summary, message}) do
        rejection = %{
          "code" => "invalid_worker_summary",
          "validator_message" => message,
          "terminal_event_type" => event_type,
          "attempted" => attempted_terminal_metadata(payload)
        }

        %{state | assignment: %{assignment | last_terminal_rejection: rejection}}
      end

      defp attempted_terminal_metadata(payload) do
        payload
        |> map_get("summary", :summary)
        |> attempted_summary_metadata()
      end

      defp attempted_summary_metadata(summary) when is_map(summary) do
        metadata =
          [{"phase", :phase}, {"outcome", :outcome}, {"reason", :reason}, {"validation_status", :validation_status}]
          |> Enum.reduce(%{}, &put_attempted_metadata(&1, summary, &2))

        case map_get(summary, "gates", :gates) do
          gates when is_list(gates) -> Map.put(metadata, "gates", attempted_gate_metadata(gates))
          _other -> metadata
        end
      end

      defp attempted_summary_metadata(_summary), do: %{}

      defp attempted_gate_metadata(gates) do
        gates
        |> Enum.with_index()
        |> Enum.flat_map(&attempted_gate_metadata_entry/1)
      end

      defp attempted_gate_metadata_entry({gate, index}) when is_map(gate) do
        metadata =
          Enum.reduce(
            [{"status", :status}, {"exit_code", :exit_code}],
            %{"index" => index},
            &put_attempted_metadata(&1, gate, &2)
          )

        [metadata]
      end

      defp attempted_gate_metadata_entry({_gate, _index}), do: []

      defp put_attempted_metadata({string_key, atom_key}, source, values) do
        case sanitize_attempted_value(map_get(source, string_key, atom_key)) do
          nil -> values
          value -> Map.put(values, string_key, value)
        end
      end

      defp sanitize_attempted_value(value) when is_binary(value) do
        value
        |> WorkerResult.normalize_detail()
        |> Redaction.credentials()
      end

      defp sanitize_attempted_value(value) when is_integer(value), do: value
      defp sanitize_attempted_value(_value), do: nil

      defp matching_assignment(nil, _worker_id, _session_id, _id), do: {:error, :lease_not_active}

      defp matching_assignment(assignment, worker_id, session_id, id) do
        if assignment.id == id and assignment.worker_id == worker_id and assignment.session_id == session_id,
          do: {:ok, assignment},
          else: {:error, :lease_not_active}
      end

      defp start_reconciliation(state) do
        state = expire_assignment(state)

        if state.reconcile_task do
          state
        else
          manager = self()
          ref = make_ref()
          workflows = distinct_slug_workflows(state.workflows.list_enabled())

          {:ok, pid} =
            Task.Supervisor.start_child(state.task_supervisor, fn ->
              result = Enum.map(workflows, &reconcile_workflow_zombies(state, &1))
              GenServer.cast(manager, {:reconcile_result, ref, result})
            end)

          timer = Process.send_after(manager, {:reconcile_timeout, ref}, state.tracker_io_timeout_ms)
          %{state | reconcile_task: %{ref: ref, pid: pid, timer: timer, workflows: workflows}}
        end
      end

      defp complete_reconciliation(%{reconcile_task: task} = state, results) do
        _ = Process.cancel_timer(task.timer)

        Enum.each(results, fn
          {:error, workflow, project_slug, reason} ->
            Logger.warning("event=worker_reconcile_tracker_error project_slug=#{project_slug} reason=#{inspect(reason)}")
            record_linear_request_failure(state.persistence, workflow, "worker_reconcile", reason)

          {:ok, _project_slug} ->
            :ok
        end)

        %{state | reconcile_task: nil}
      end

      defp reconcile_workflow_zombies(state, workflow) do
        project_slug = get_in(workflow.config, ["tracker", "project_slug"])

        Config.with_workflow_context(workflow, fn ->
          fetch_and_reconcile_workflow_zombies(state, workflow, project_slug)
        end)
      end

      defp fetch_and_reconcile_workflow_zombies(state, workflow, project_slug) do
        case state.tracker.fetch_issues_by_states(["In Progress"]) do
          {:ok, issues} ->
            Enum.each(issues, &reconcile_zombie(state, &1))
            {:ok, project_slug}

          {:error, reason} ->
            {:error, workflow, project_slug, reason}
        end
      end

      defp reconcile_zombie(%{claim_task: %{operation: {:activate, %{issue: %{id: issue_id}}}}}, %Issue{id: issue_id}), do: :ok
      defp reconcile_zombie(%{claim_task: %{operation: {:abort, %{issue: %{id: issue_id}}, _reason}}}, %Issue{id: issue_id}), do: :ok

      defp reconcile_zombie(%{assignment: %{issue: %{id: issue_id}}}, %Issue{id: issue_id}), do: :ok

      defp reconcile_zombie(state, %Issue{} = issue) do
        case state.persistence.list_runs_for_issue(issue.identifier, limit: 1) do
          [run | _] -> maybe_requeue_zombie(state, issue, run)
          _none -> :ok
        end
      end

      defp maybe_requeue_zombie(state, issue, %{status: "running", started_at: %DateTime{} = started_at} = run) do
        cutoff = DateTime.add(state.now.(), -state.persistence.worker_lease_duration_seconds(), :second)

        if DateTime.compare(started_at, cutoff) == :lt do
          record_orphan_signal(state.persistence, issue, run, started_at)
        end
      end

      defp maybe_requeue_zombie(_state, _issue, _run), do: :ok

      defp record_orphan_signal(persistence, issue, run, started_at) do
        case persistence.list_events(run_id: run.id, event_type: "run.orphaned", limit: 1) do
          [] ->
            persistence.record_event(%{
              project_id: run.project_id,
              run_id: run.id,
              issue_identifier: issue.identifier,
              event_type: "run.orphaned",
              payload: %{
                "reason" => "assignment_missing_after_lease_window",
                "started_at" => DateTime.to_iso8601(started_at),
                "operator_action" => "comment_and_move_to_todo"
              }
            })

          [_event | _rest] ->
            :ok

          {:error, _reason} = error ->
            error
        end
      end

      defp record_linear_request_failure(persistence, workflow, operation, reason) do
        persistence.record_event(%{
          project_id: workflow.project_id,
          event_type: "linear.request_failed",
          payload:
            reason
            |> linear_failure_payload()
            |> Map.merge(%{
              "operation" => operation,
              "project_slug" => get_in(workflow.config, ["tracker", "project_slug"])
            })
        })
      end

      defp linear_failure_payload({:linear_api_status, status, _body}) when is_integer(status),
        do: %{"status" => status, "reason" => "http_status"}

      defp linear_failure_payload({:linear_api_request, reason}),
        do: %{"reason" => "transport:#{reason}"}

      defp linear_failure_payload(reason), do: %{"reason" => inspect(reason, limit: 20, printable_limit: 500)}

      defp distinct_slug_workflows(workflows),
        do: Enum.uniq_by(workflows, &get_in(&1.config, ["tracker", "project_slug"]))

      defp schedule_reconciliation(state) do
        Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
      end

      defp available_slots(attrs), do: map_get(attrs, "available_slots", :available_slots) || 0
      defp total_slots(attrs), do: map_get(attrs, "total_slots", :total_slots)

      defp worker_session_liveness(state, worker_id, session_id) do
        case Map.get(state.liveness, {worker_id, session_id}) do
          nil ->
            {:error, :worker_session_not_found}

          %{worker: worker, session: session} = entry ->
            if fresh_liveness?(state, entry), do: {:ok, worker, session}, else: {:error, :worker_session_stale}
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
        entry = %{worker: worker, session: session, total_slots: total_slots, last_seen_at: state.now.()}
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
        %{capacity: if(reason == :assigned, do: 1, else: 0), reason: reason, listening_mode: listening_mode}
      end

      defp blocking_decision_evidence(issue, decision, listening_mode) do
        :blocking_decision
        |> admission_evidence(listening_mode)
        |> Map.merge(%{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          blocking_decision: Map.take(decision, ["decided_at", "origin_state", "reason", "run_id"])
        })
      end

      defp merge_candidate_skip(_current, {:skip, :blocking_decision, evidence}), do: {:skip, :blocking_decision, evidence}
      defp merge_candidate_skip({:skip, :blocking_decision, _evidence} = current, _next), do: current
      defp merge_candidate_skip(_current, {:skip, :listening_mode, evidence}), do: {:skip, :listening_mode, evidence}

      defp merge_empty_evidence(%{reason: :blocking_decision} = evidence, _next_evidence), do: evidence
      defp merge_empty_evidence(_evidence, %{reason: :blocking_decision} = next_evidence), do: next_evidence
      defp merge_empty_evidence(%{reason: :listening_mode} = evidence, _next_evidence), do: evidence
      defp merge_empty_evidence(_evidence, %{reason: :listening_mode} = next_evidence), do: next_evidence
      defp merge_empty_evidence(_evidence, %{reason: :active_run} = next_evidence), do: next_evidence
      defp merge_empty_evidence(evidence, _next_evidence), do: evidence

      defp log_admission_skip(:blocking_decision, worker_id, session_id, evidence) do
        blocking_reason = get_in(evidence, [:blocking_decision, "reason"])
        origin_state = get_in(evidence, [:blocking_decision, "origin_state"])
        run_id = get_in(evidence, [:blocking_decision, "run_id"])
        decided_at = get_in(evidence, [:blocking_decision, "decided_at"])

        Logger.info(
          "event=worker_claim_skip issue_id=#{evidence.issue_id} issue_identifier=#{evidence.issue_identifier} worker_id=#{worker_id} session_id=#{session_id} skip_reason=blocking_decision blocking_reason=#{inspect(blocking_reason)} origin_state=#{inspect(origin_state)} run_id=#{inspect(run_id)} decided_at=#{inspect(decided_at)} listening_mode=#{evidence.listening_mode} capacity=#{evidence.capacity}"
        )
      end

      defp log_admission_skip(reason, worker_id, session_id, evidence)
           when reason in [:not_listening, :listening_mode] do
        Logger.info("event=worker_claim_skip worker_id=#{worker_id} session_id=#{session_id} skip_reason=#{reason} listening_mode=#{evidence.listening_mode} capacity=#{evidence.capacity}")
      end

      defp log_admission_skip(_reason, _worker_id, _session_id, _evidence), do: :ok

      defp environment_failure_circuit_evidence(circuit, listening_mode) do
        :environment_failure_circuit_open
        |> admission_evidence(listening_mode)
        |> Map.put(:failure_fingerprint, circuit.triggering_fingerprint)
      end

      defp record_environment_failure_circuit(state, assignment, "task.completed", _terminal) do
        EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
      end

      defp record_environment_failure_circuit(state, assignment, "task.cancelled", _terminal) do
        EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
      end

      defp record_environment_failure_circuit(state, assignment, "task.failed", :completed) do
        EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
      end

      defp record_environment_failure_circuit(
             state,
             assignment,
             "task.failed",
             %RunFailure{classification: "cancelled"}
           ) do
        EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
      end

      defp record_environment_failure_circuit(state, assignment, "task.failed", %RunFailure{} = failure) do
        circuit =
          EnvironmentFailureCircuit.record_failure(
            assignment.issue_identifier,
            RunFailure.reason(failure),
            %{issue_id: assignment.issue.id, run_id: assignment.run_id},
            state.failure_circuit
          )

        if circuit.alert do
          state.persistence.record_event(EnvironmentFailureCircuit.alert_event_attrs(circuit, assignment.project_id))
        end
      end

      defp record_environment_failure_circuit(_state, _assignment, _event_type, _summary), do: :ok

      defp terminal_result(event_type, summary) when event_type in @terminal_events,
        do: RunFailure.from_worker_summary(event_type, summary)

      defp terminal_result(event_type, _summary) when event_type not in @terminal_events, do: nil

      defp validate_correlation(payload, correlation) do
        validate_correlation_fields(Map.get(payload, "correlation", %{}), correlation)
      end

      defp validate_correlation_fields(supplied, authoritative) do
        Enum.reduce_while(supplied, :ok, fn {key, value}, :ok ->
          if Map.has_key?(authoritative, key) and authoritative[key] != value,
            do: {:halt, {:error, {:correlation_mismatch, key}}},
            else: {:cont, :ok}
        end)
      end

      defp map_get(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)
      defp process_alive?(server), do: GenServer.whereis(server) != nil

      defp active_lease_ids(attrs), do: map_get(attrs, "active_leases", :active_leases) || []

      defp heartbeat_assignment(_worker_id, _session_id, [], _server), do: {:ok, %{lease_renewals: [], commands: []}}

      defp heartbeat_assignment(worker_id, session_id, active_ids, server) do
        if process_alive?(server) do
          deadline_ms = System.monotonic_time(:millisecond) + @heartbeat_timeout_ms

          try do
            GenServer.call(server, {:heartbeat, worker_id, session_id, active_ids, deadline_ms}, @heartbeat_timeout_ms)
          catch
            :exit, {:timeout, _call} -> heartbeat_unavailable()
          end
        else
          {:ok, %{lease_renewals: [], commands: []}}
        end
      end

      defp heartbeat_unavailable, do: {:error, {:heartbeat_unavailable, @heartbeat_retry_after_seconds}}

      defp matching_project_assignment(nil, _project_id), do: :error
      defp matching_project_assignment(assignment, nil), do: {:ok, assignment}
      defp matching_project_assignment(%{project_id: project_id} = assignment, project_id), do: {:ok, assignment}
      defp matching_project_assignment(_assignment, _project_id), do: :error

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

      defp add_cancel_waiter(cancellation, from), do: %{cancellation | waiters: [from | cancellation.waiters]}

      defp mark_cancel_delivered(%{cancellation: cancellation} = assignment) do
        %{assignment | cancellation: %{cancellation | delivered?: true}}
      end

      defp cancel_command(%{id: task_id, cancellation: cancellation}) do
        %{"type" => "cancel_task", "task_id" => task_id, "reason" => cancellation.reason}
      end

      defp complete_pending_cancellation(state, %{cancellation: cancellation} = assignment, "task.cancelled", :ok) do
        cancel_timer(cancellation)
        reply_cancel_waiters(cancellation, cancelled_assignment(assignment, cancellation.project_id))
        state
      end

      defp complete_pending_cancellation(state, %{cancellation: cancellation} = assignment, event_type, :ok)
           when event_type in @terminal_events do
        cancel_timer(cancellation)
        result = failed_cancellation(assignment, :worker_terminal_not_cancelled, cancellation.project_id)
        reply_cancel_waiters(cancellation, result)
        state
      end

      defp complete_pending_cancellation(state, %{cancellation: cancellation} = assignment, event_type, {:error, reason})
           when event_type in @terminal_events do
        cancel_timer(cancellation)
        result = failed_cancellation(assignment, {:terminal_event_failed, reason}, cancellation.project_id)
        reply_cancel_waiters(cancellation, result)
        %{state | assignment: %{assignment | cancellation: %{cancellation | waiters: [], timer: nil}}}
      end

      defp complete_pending_cancellation(state, _assignment, _event_type, _result), do: state

      defp assignment_after_event(_state, event_type) when event_type in @terminal_events, do: nil
      defp assignment_after_event(state, _event_type), do: state.assignment

      defp cancel_timer(%{timer: nil}), do: :ok
      defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)

      defp reply_cancel_waiters(%{waiters: waiters}, result) do
        Enum.each(waiters, &GenServer.reply(&1, result))
      end

      defp cancellation_timeout_reason(%{delivered?: true}), do: :worker_termination_timeout
      defp cancellation_timeout_reason(%{delivered?: false}), do: :worker_cancel_delivery_timeout

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
        if map_get(payload, "phase", :phase) == "source_preparation" do
          send(state.orchestrator, {:system_worker_update, assignment.issue.id, source_progress_update(payload)})
        else
          Orchestrator.worker_task_progress(assignment.issue.id, payload, state.orchestrator)
        end
      end

      defp notify_orchestrator(state, assignment, event_type, payload, terminal)
           when event_type in @terminal_events do
        outcome =
          case {event_type, terminal, get_in(payload, ["summary", "outcome"])} do
            {"task.completed", :completed, _outcome} ->
              :success

            {"task.cancelled", %RunFailure{}, _outcome} ->
              :cancelled

            {"task.failed", :completed, _outcome} ->
              :success

            {"task.failed", %RunFailure{classification: "cancelled"}, _outcome} ->
              :cancelled

            {"task.failed", %RunFailure{} = failure, "blocked"} ->
              {:blocked, failure}

            {"task.failed", %RunFailure{} = failure, _outcome} ->
              {:failed, failure}
          end

        notify_worker_terminal(state, assignment, outcome)
      end

      defp notify_orchestrator(_state, _assignment, _event_type, _payload, _summary), do: :ok

      defp source_progress_update(payload) do
        %{
          source: map_get(payload, "source", :source),
          phase: map_get(payload, "phase", :phase),
          operation: map_get(payload, "operation", :operation),
          status: map_get(payload, "status", :status),
          detail: map_get(payload, "detail", :detail),
          occurred_at: map_get(payload, "occurred_at", :occurred_at)
        }
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

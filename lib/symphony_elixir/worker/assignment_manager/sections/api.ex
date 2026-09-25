# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Worker.AssignmentManager.Sections.Api do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use GenServer

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

      @terminal_events ["task.completed", "task.failed", "task.cancelled"]
      @initial_poll_seconds 5
      @backoff_poll_seconds 30
      @max_poll_seconds 60
      @heartbeat_timeout_ms 1000
      @heartbeat_retry_after_seconds 1
      @cancel_timeout_ms 30_000
      @cancel_call_timeout_ms @cancel_timeout_ms + 1000

      @type assignment :: map()
      @type liveness_entry :: %{
              required(:worker) => map(),
              required(:session) => map(),
              required(:total_slots) => pos_integer(),
              required(:last_seen_at) => DateTime.t()
            }
      @type cancellation_result :: %{
              required(:status) => String.t(),
              required(:cancelled) => non_neg_integer(),
              required(:failed) => [map()],
              required(:tasks) => [map()],
              optional(:project_id) => String.t() | nil
            }

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
      end

      @spec claim_with_policy(
              String.t(),
              String.t(),
              map(),
              Orchestrator.listening_mode(),
              pos_integer(),
              GenServer.server()
            ) ::
              {:ok, assignment() | {:empty, pos_integer()}}
              | {:error, term()}
              | {:error, term(), pos_integer()}
      def claim_with_policy(
            worker_id,
            session_id,
            attrs,
            listening_mode,
            max_concurrent_agents,
            server \\ __MODULE__
          ) do
        case claim_with_policy_evidence(
               worker_id,
               session_id,
               attrs,
               listening_mode,
               max_concurrent_agents,
               server
             ) do
          {:ok, result, _evidence} -> {:ok, result}
          {:error, reason, seconds} -> {:error, reason, seconds}
          {:error, reason} -> {:error, reason}
        end
      end

      @spec claim_with_policy_evidence(
              String.t(),
              String.t(),
              map(),
              Orchestrator.listening_mode(),
              pos_integer(),
              GenServer.server()
            ) ::
              {:ok, assignment() | {:empty, pos_integer()}, map()}
              | {:error, term()}
              | {:error, term(), pos_integer()}
      def claim_with_policy_evidence(
            worker_id,
            session_id,
            attrs,
            listening_mode,
            max_concurrent_agents,
            server \\ __MODULE__
          ) do
        if process_alive?(server) do
          GenServer.call(
            server,
            {:claim, worker_id, session_id, attrs, listening_mode, max_concurrent_agents},
            :infinity
          )
        else
          {:ok, {:empty, @initial_poll_seconds}, admission_evidence(:worker_dispatch_disabled, listening_mode)}
        end
      end

      @spec reject_claim(String.t(), String.t(), :not_listening) ::
              {:ok, {:empty, pos_integer()}, map()}
      def reject_claim(worker_id, session_id, :not_listening) do
        evidence = admission_evidence(:not_listening, :not_listening)
        log_admission_skip(:not_listening, worker_id, session_id, evidence)
        {:ok, {:empty, @initial_poll_seconds}, evidence}
      end

      @spec observe_session(map(), map(), GenServer.server()) :: :ok
      def observe_session(%{id: worker_id} = worker, %{id: session_id} = session, server \\ __MODULE__)
          when is_binary(worker_id) and is_binary(session_id) do
        if process_alive?(server) do
          GenServer.call(server, {:observe_session, worker, session}, :infinity)
        else
          :ok
        end
      end

      @spec observe_liveness(String.t(), String.t(), map(), GenServer.server()) :: :ok
      def observe_liveness(worker_id, session_id, attrs, server \\ __MODULE__) do
        if process_alive?(server) do
          GenServer.cast(server, {:observe_liveness, worker_id, session_id, attrs})
        else
          :ok
        end
      end

      @spec available_worker_slots(GenServer.server()) :: non_neg_integer()
      def available_worker_slots(server \\ __MODULE__) do
        if process_alive?(server) do
          GenServer.call(server, :available_worker_slots)
        else
          0
        end
      end

      @spec heartbeat(String.t(), String.t(), map(), GenServer.server(), module()) ::
              {:ok, map()} | {:error, term()}
      def heartbeat(
            worker_id,
            session_id,
            attrs,
            server \\ __MODULE__,
            persistence \\ PersistenceProvider.module()
          ) do
        active_ids = active_lease_ids(attrs)
        observe_liveness(worker_id, session_id, attrs, server)
        HeartbeatHistory.observe(worker_id, session_id, persistence)

        with {:ok, heartbeat} <- heartbeat_assignment(worker_id, session_id, active_ids, server) do
          {:ok,
           %{
             ok: true,
             server_time: DateTime.utc_now(),
             lease_renewals: Map.fetch!(heartbeat, :lease_renewals),
             commands: Map.fetch!(heartbeat, :commands)
           }}
        end
      end

      @spec record_event(String.t(), String.t(), String.t(), String.t(), map(), GenServer.server()) ::
              {:ok, map()} | {:error, term()}
      def record_event(worker_id, session_id, assignment_id, event_type, payload, server \\ __MODULE__) do
        record_event_with_liveness(
          worker_id,
          session_id,
          assignment_id,
          event_type,
          payload,
          %{},
          server
        )
      end

      @spec record_event_with_liveness(
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              map(),
              map(),
              GenServer.server()
            ) ::
              {:ok, map()} | {:error, term()}
      def record_event_with_liveness(
            worker_id,
            session_id,
            assignment_id,
            event_type,
            payload,
            attrs,
            server \\ __MODULE__
          ) do
        if process_alive?(server) do
          GenServer.call(
            server,
            {:event, worker_id, session_id, assignment_id, event_type, payload, attrs}
          )
        else
          {:error, :lease_not_active}
        end
      end

      @spec current_assignment(GenServer.server()) :: assignment() | nil
      def current_assignment(server \\ __MODULE__) do
        if process_alive?(server) do
          GenServer.call(server, :current_assignment)
        else
          nil
        end
      end

      @spec cancel_current(String.t()) :: cancellation_result()
      def cancel_current(reason) do
        cancel_current(reason, nil, __MODULE__)
      end

      @spec cancel_current(String.t(), GenServer.server() | String.t() | nil) :: cancellation_result()
      def cancel_current(reason, server) when is_atom(server) or is_pid(server) or is_tuple(server) do
        cancel_current(reason, nil, server)
      end

      def cancel_current(reason, project_id) when is_binary(project_id) or is_nil(project_id) do
        cancel_current(reason, project_id, __MODULE__)
      end

      @spec cancel_current(String.t(), String.t() | nil, GenServer.server()) :: cancellation_result()
      def cancel_current(reason, project_id, server) when is_binary(project_id) or is_nil(project_id) do
        if process_alive?(server) do
          GenServer.call(server, {:cancel_current, reason, project_id}, @cancel_call_timeout_ms)
        else
          no_active_assignment(project_id)
        end
      end

      @spec reconcile(GenServer.server()) :: :ok
      def reconcile(server \\ __MODULE__) do
        GenServer.cast(server, :reconcile)
      end

      @impl true
      def init(opts) do
        state = %{
          assignment: nil,
          tracker: Keyword.get(opts, :tracker, Tracker),
          persistence: Keyword.get(opts, :persistence, PersistenceProvider.module()),
          workflows: Keyword.get(opts, :workflows, WorkflowStore),
          orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
          now: Keyword.get(opts, :now, &DateTime.utc_now/0),
          failure_circuit: Keyword.get(opts, :failure_circuit, EnvironmentFailureCircuit),
          reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, 10_000),
          empty_claim_streak: 0,
          tracker_error_streak: 0,
          liveness: %{}
        }

        schedule_reconciliation(state)
        {:ok, state}
      end

      @impl true
      def handle_cast(:reconcile, state) do
        {:noreply, reconcile_zombies(state)}
      end

      def handle_cast({:observe_liveness, worker_id, session_id, attrs}, state) do
        {:noreply, observe_request_liveness(state, worker_id, session_id, attrs)}
      end

      @impl true
      def handle_info(:reconcile, state) do
        state = reconcile_zombies(state)
        schedule_reconciliation(state)
        {:noreply, state}
      end

      def handle_info(
            {:cancel_timeout, ref},
            %{assignment: %{cancellation: %{ref: ref} = cancellation} = assignment} = state
          ) do
        result =
          failed_cancellation(
            assignment,
            cancellation_timeout_reason(cancellation),
            cancellation.project_id
          )

        reply_cancel_waiters(cancellation, result)
        cancellation = %{cancellation | waiters: [], timer: nil}
        {:noreply, %{state | assignment: %{assignment | cancellation: cancellation}}}
      end

      def handle_info({:cancel_timeout, _ref}, state) do
        {:noreply, state}
      end

      @impl true
      def handle_call(:current_assignment, _from, state) do
        {:reply, state.assignment, state}
      end

      def handle_call(:available_worker_slots, _from, state) do
        {:reply, fresh_liveness_capacity(state), state}
      end

      def handle_call({:observe_session, worker, session}, _from, state) do
        {:reply, :ok, observe_session_liveness(state, worker, session)}
      end

      def handle_call({:cancel_current, reason, project_id}, from, state) do
        state = expire_assignment(state)

        case matching_project_assignment(state.assignment, project_id) do
          {:ok, %{cancellation: cancellation} = assignment} ->
            {:noreply, %{state | assignment: %{assignment | cancellation: add_cancel_waiter(cancellation, from)}}}

          {:ok, assignment} ->
            {:noreply,
             %{
               state
               | assignment: Map.put(assignment, :cancellation, new_cancellation(reason, project_id, from))
             }}

          :error ->
            {:reply, no_active_assignment(project_id), state}
        end
      end

      def handle_call(
            {:claim, worker_id, session_id, attrs, listening_mode, max_concurrent_agents},
            _from,
            state
          ) do
        state = expire_assignment(state)
        liveness = worker_session_liveness(state, worker_id, session_id)
        state = observe_request_liveness(state, worker_id, session_id, attrs)

        result =
          with {:ok, worker, session} <- liveness,
               true <- available_slots(attrs) > 0,
               :allow <- EnvironmentFailureCircuit.check(state.failure_circuit),
               nil <- state.assignment do
            case claim_from_workflows(state, worker, session, listening_mode, max_concurrent_agents) do
              {:ok, nil, evidence} ->
                {:ok, nil, evidence}

              {:ok, assignment} ->
                Orchestrator.worker_task_started(assignment, state.orchestrator)
                {:ok, assignment, admission_evidence(:assigned, listening_mode)}

              error ->
                error
            end
          else
            {:block, circuit} ->
              {:bypass, @max_poll_seconds, environment_failure_circuit_evidence(circuit, listening_mode)}

            %{} ->
              {:bypass, @initial_poll_seconds, admission_evidence(:active_assignment, listening_mode)}

            false ->
              {:bypass, @initial_poll_seconds, admission_evidence(:no_available_slots, listening_mode)}

            {:error, reason} when reason in [:worker_session_not_found, :worker_session_stale] ->
              {:bypass, @initial_poll_seconds, admission_evidence(reason, listening_mode)}

            {:error, reason} ->
              {:error, reason}
          end

        case result do
          {:ok, %{} = assignment, evidence} ->
            state = %{state | assignment: assignment, empty_claim_streak: 0, tracker_error_streak: 0}
            {:reply, {:ok, assignment, evidence}, state}

          {:ok, nil, evidence} ->
            streak = state.empty_claim_streak + 1
            seconds = empty_poll_seconds(streak)

            {:reply, {:ok, {:empty, seconds}, evidence}, %{state | empty_claim_streak: streak, tracker_error_streak: 0}}

          {:bypass, seconds, evidence} ->
            {:reply, {:ok, {:empty, seconds}, evidence}, state}

          {:error, reason} = error ->
            if tracker_backoff_error?(reason) do
              streak = state.tracker_error_streak + 1
              seconds = failure_poll_seconds(streak)
              {:reply, {:error, reason, seconds}, %{state | tracker_error_streak: streak}}
            else
              {:reply, error, state}
            end
        end
      end

      def handle_call({:heartbeat, worker_id, session_id, active_ids, deadline_ms}, _from, state) do
        if System.monotonic_time(:millisecond) > deadline_ms do
          {:reply, heartbeat_unavailable(), state}
        else
          {assignment, heartbeat} =
            assignment_heartbeat(state.assignment, worker_id, session_id, active_ids, state)

          {:reply, {:ok, heartbeat}, %{state | assignment: assignment}}
        end
      end

      def handle_call(
            {:event, worker_id, session_id, assignment_id, event_type, payload, attrs},
            _from,
            state
          ) do
        state = expire_assignment(state)
        state = observe_request_liveness(state, worker_id, session_id, attrs)

        case matching_assignment(state.assignment, worker_id, session_id, assignment_id) do
          {:ok, assignment} ->
            with :ok <- validate_correlation(payload, assignment.correlation),
                 {:ok, summary} <- WorkerResult.validate_event(event_type, payload),
                 {:ok, event} <-
                   persist_event(state.persistence, assignment, event_type, payload, summary),
                 :ok <- transition_run(state.persistence, assignment.run_id, event_type, summary) do
              record_environment_failure_circuit(state, assignment, event_type, summary)

              notify_orchestrator(
                state,
                assignment,
                event_type,
                event_payload_with_time(payload, event),
                summary
              )

              state = complete_pending_cancellation(state, assignment, event_type, :ok)
              {:reply, {:ok, event}, %{state | assignment: assignment_after_event(state, event_type)}}
            else
              {:error, reason} ->
                state = complete_pending_cancellation(state, assignment, event_type, {:error, reason})
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end

      defp claim_from_workflows(state, worker, session, listening_mode, max_concurrent_agents) do
        empty = {:ok, nil, admission_evidence(:no_eligible_candidate, listening_mode)}

        Enum.reduce_while(state.workflows.list_enabled(), empty, fn workflow, {:ok, nil, evidence} ->
          result =
            Config.with_workflow_context(workflow, fn ->
              dispatch_settings =
                Orchestrator.dispatch_policy_settings(listening_mode, max_concurrent_agents)

              claim_from_workflow(state, worker, session, workflow, dispatch_settings)
            end)

          case result do
            {:ok, nil, next_evidence} ->
              {:cont, {:ok, nil, merge_empty_evidence(evidence, next_evidence)}}

            {:ok, %{} = assignment} ->
              {:halt, {:ok, assignment}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        end)
      end

      defp empty_poll_seconds(1) do
        @initial_poll_seconds
      end

      defp empty_poll_seconds(streak) when streak in 2..5 do
        @backoff_poll_seconds
      end

      defp empty_poll_seconds(_streak) do
        @max_poll_seconds
      end

      defp failure_poll_seconds(1) do
        @backoff_poll_seconds
      end

      defp failure_poll_seconds(_streak) do
        @max_poll_seconds
      end

      defp tracker_backoff_error?({:linear_api_status, status, _body})
           when status == 429 or status in 500..599 do
        true
      end

      defp tracker_backoff_error?({:linear_api_request, _reason}) do
        true
      end

      defp tracker_backoff_error?(_reason) do
        false
      end

      defp claim_from_workflow(state, worker, session, workflow, dispatch_settings) do
        with {:ok, candidates} <- state.tracker.fetch_candidate_issues(),
             {:ok, %Issue{} = candidate} <-
               select_candidate(candidates, state.persistence, dispatch_settings),
             {:ok, %Issue{} = issue} <-
               revalidate(candidate, state.tracker, state.persistence, dispatch_settings),
             {:ok, assignment} <- create_assignment(state, worker, session, workflow, issue) do
          {:ok, assignment}
        else
          {:skip, reason, evidence} ->
            log_admission_skip(reason, worker.id, session.id, evidence)
            {:ok, nil, evidence}

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp select_candidate(candidates, persistence, dispatch_settings) do
        listening_mode = DispatchPolicy.listening_mode(dispatch_settings)

        candidates
        |> DispatchPolicy.sort_issues_for_dispatch()
        |> Enum.reduce_while(
          {:skip, :no_eligible_candidate, admission_evidence(:no_eligible_candidate, listening_mode)},
          fn issue, skip ->
            case candidate_admission(issue, persistence, dispatch_settings) do
              :ok ->
                {:halt, {:ok, issue}}

              {:skip, :blocking_decision, _evidence} = blocking ->
                {:cont, merge_candidate_skip(skip, blocking)}

              {:skip, :listening_mode, _evidence} = filtered ->
                {:cont, merge_candidate_skip(skip, filtered)}

              {:skip, _reason, _evidence} ->
                {:cont, skip}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end
        )
      end

      defp candidate_admission(%Issue{} = issue, persistence, dispatch_settings) do
        listening_mode = DispatchPolicy.listening_mode(dispatch_settings)

        with true <- DispatchPolicy.allowed_by_listening_mode?(issue.state, dispatch_settings),
             :ok <- live_issue_admission(issue, listening_mode),
             :ok <- blocking_decision_admission(issue, persistence, listening_mode) do
          if dispatchable_from_history?(issue, persistence) do
            :ok
          else
            {:skip, :run_history, admission_evidence(:run_history, listening_mode)}
          end
        else
          false ->
            {:skip, :listening_mode, admission_evidence(:listening_mode, listening_mode)}

          other ->
            other
        end
      end

      defp dispatchable_from_history?(%Issue{} = issue, persistence) do
        if worker_started_state?(issue.state) do
          case persistence.list_runs_for_issue(issue.identifier, limit: 1) do
            [%{status: status} | _] -> status in ["succeeded", "failed", "cancelled"]
            [] -> false
            {:error, _reason} -> false
          end
        else
          true
        end
      end

      defp live_issue_admission(%Issue{} = issue, listening_mode) do
        normalized = SymphonyElixir.StateName.normalize(issue.state)
        active = Config.settings!().tracker.active_states |> DispatchPolicy.normalized_state_set()

        cond do
          not MapSet.member?(active, normalized) ->
            {:skip, :stale, admission_evidence(:stale, listening_mode)}

          issue.blocked_by != [] ->
            {:skip, :dependency, admission_evidence(:dependency, listening_mode)}

          Config.human_review_state?(issue.state) ->
            {:skip, :human_review, admission_evidence(:human_review, listening_mode)}

          true ->
            :ok
        end
      end

      defp blocking_decision_admission(%Issue{} = issue, persistence, listening_mode) do
        case persistence.get_issue_by_identifier(issue.identifier) do
          %{blocking_decision: %{} = decision} ->
            {:skip, :blocking_decision, blocking_decision_evidence(issue, decision, listening_mode)}

          %{} ->
            :ok

          nil ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp revalidate(%Issue{id: issue_id}, tracker, persistence, dispatch_settings) do
        case tracker.fetch_issue_states_by_ids([issue_id]) do
          {:ok, [%Issue{} = issue | _]} ->
            case candidate_admission(issue, persistence, dispatch_settings) do
              :ok -> {:ok, issue}
              other -> other
            end

          {:ok, []} ->
            {:skip, :missing, admission_evidence(:missing, DispatchPolicy.listening_mode(dispatch_settings))}

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp create_assignment(state, worker, session, workflow, issue) do
        now = state.now.()
        assignment_id = Ecto.UUID.generate()
        expires_at = DateTime.add(now, state.persistence.worker_lease_duration_seconds(), :second)
        project_id = workflow.project_id
        profile = Config.workflow_profile_for_state(issue.state)

        with {:ok, issue_record} <-
               state.persistence.upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id)),
             {:ok, run} <-
               create_run(state.persistence, issue, workflow, issue_record.id, project_id, now),
             {:ok, issue} <- move_to_worker_started(state.tracker, issue, profile),
             prompt <-
               PromptBuilder.build_prompt(issue,
                 profile: profile,
                 profile_policy: Config.workflow_profile(profile),
                 allowed_updates: Config.workflow_allowed_updates(profile)
               ),
             assignment <-
               build_assignment(assignment_id, issue, run, worker, session, workflow,
                 prompt: prompt,
                 profile: profile,
                 expires_at: expires_at
               ),
             {:ok, _event} <-
               state.persistence.record_event(assignment_event(assignment, "task.accepted", %{})) do
          {:ok, assignment}
        else
          {:error, reason} = error ->
            close_failed_run(state.persistence, issue.identifier, reason)
            error
        end
      end
    end
  end
end

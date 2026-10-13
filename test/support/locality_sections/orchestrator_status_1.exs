# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.OrchestratorStatus1 do
  @moduledoc false

  alias SymphonyElixir.{BlockingDecision, Orchestrator}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TestSupport.FakePersistence

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      use SymphonyElixir.TestSupport

      defp restart_orchestrator_if_stopped do
        if is_nil(Process.whereis(Orchestrator)) do
          case Supervisor.restart_child(SymphonyElixir.Supervisor, Orchestrator) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
        end
      end

      defp restore_process_state_if_alive(pid, state) do
        if Process.alive?(pid), do: :sys.replace_state(pid, fn _ -> state end)
      end

      defmodule RollbackLinearClient do
        def fetch_issues_by_states(_states), do: {:ok, []}
        def fetch_candidate_issues, do: {:ok, []}

        def fetch_issue_states_by_ids(issue_ids) do
          send(test_pid(), {:fetch_issue_states_by_ids, issue_ids})
          state = Application.get_env(:symphony_elixir, :rollback_linear_state, "In Progress")
          {:ok, Enum.map(issue_ids, &%Issue{id: &1, identifier: "MT-ROLLBACK", state: state, title: "Rollback"})}
        end

        def graphql(_query, %{issueId: issue_id, stateName: state_name}) do
          send(test_pid(), {:resolve_state, issue_id, state_name})
          {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-ready"}]}}}}}}
        end

        def graphql(_query, %{issueId: issue_id, stateId: state_id}) do
          send(test_pid(), {:update_issue_state_id, issue_id, state_id})
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        end

        def graphql(_query, %{issueId: issue_id, body: body}) do
          send(test_pid(), {:create_comment, issue_id, body})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        end

        defp test_pid, do: Application.fetch_env!(:symphony_elixir, :rollback_linear_test_pid)
      end

      test "snapshot returns :timeout when snapshot server is unresponsive" do
        server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
        parent = self()

        pid =
          spawn(fn ->
            Process.register(self(), server_name)
            send(parent, :snapshot_server_ready)

            receive do
              :stop -> :ok
            end
          end)

        assert_receive :snapshot_server_ready, 1_000
        assert Orchestrator.snapshot(server_name, 10) == :timeout

        send(pid, :stop)
      end

      test "linear task update completion preserves the live Orchestrator state invariant" do
        issue_id = "issue-linear-update"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-UPDATE",
          title: "Linear update",
          description: "Preserve state",
          state: "In Progress",
          url: "https://example.org/issues/MT-UPDATE"
        }

        orchestrator_name = Module.concat(__MODULE__, :LinearUpdateStateOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid), do: Process.exit(pid, :normal)
        end)

        initial_state = :sys.get_state(pid)

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: make_ref(),
          run_id: "run-linear-update",
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now()
        }

        :sys.replace_state(pid, fn state ->
          %{state | running: %{issue_id => running_entry}}
        end)

        assert %Orchestrator.State{} = :sys.get_state(pid)

        send(pid, {:linear_task_update_result, issue_id, {:ok, %{"handoff" => %{}}}, %{}, %{}, "Ready to Merge"})

        assert %Orchestrator.State{} = state = :sys.get_state(pid)
        assert state.running[issue_id].implementation_handoff_completed

        assert %{running: [_]} = Orchestrator.snapshot(orchestrator_name, 1_000)
        assert Process.alive?(pid)
        assert initial_state.__struct__ == state.__struct__
      end

      test "SYM-48-shaped handoff with empty blockers persists no reported-blocker decision" do
        issue_id = "issue-sym-48"

        issue = %Issue{
          id: issue_id,
          identifier: "SYM-48",
          title: "Successful handoff",
          state: "In Progress"
        }

        FakePersistence.put_issues([
          %{
            identifier: issue.identifier,
            tracker_issue_id: issue_id,
            blocking_decision: nil,
            no_progress_streak: 0
          }
        ])

        orchestrator_name = Module.concat(__MODULE__, :EmptyBlockerHandoffOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid), do: Process.exit(pid, :normal)
        end)

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: make_ref(),
          run_id: "8d2a2878",
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now()
        }

        :sys.replace_state(pid, fn state ->
          %{state | running: %{issue_id => running_entry}}
        end)

        tool_result = %{"result" => %{"blockers" => ""}}

        message =
          {:linear_task_update_result, issue_id, {:ok, %{"handoff" => %{}}}, tool_result, %{"branch" => "vikingmew-sym-48"}, "Ready to Merge"}

        send(pid, message)

        state = :sys.get_state(pid)
        assert state.running[issue_id].implementation_handoff_completed
        assert FakePersistence.get_issue_by_identifier("SYM-48").blocking_decision == nil
        assert FakePersistence.list_blocked_issues() == []
      end

      test "manual blocking-decision clear is typed and removes only matching runtime projections" do
        issue_id = "issue-manual-clear"
        identifier = "SYM-CLEAR"

        decision =
          BlockingDecision.new(
            :reported_blocker,
            "operator action required",
            "run-manual-clear",
            "In Progress"
          )

        FakePersistence.put_issues([
          %{
            identifier: identifier,
            tracker_issue_id: issue_id,
            snapshot: %{"state" => "Blocked"},
            blocking_decision: decision,
            no_progress_streak: 2
          }
        ])

        persisted_run = %{
          id: "run-manual-clear",
          issue_identifier: identifier,
          status: "blocked"
        }

        FakePersistence.put_runs([persisted_run])

        orchestrator_name = Module.concat(__MODULE__, :ManualDecisionClearOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
        on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

        blocked_entry = %{
          issue_id: issue_id,
          identifier: identifier,
          state: "Blocked",
          run_id: "run-manual-clear",
          worker_host: nil,
          workspace_path: nil,
          session_id: nil,
          reason: "reported_blocker",
          detail: "operator action required",
          blocked_at: decision["decided_at"],
          blocking_decision: %{
            reason: decision["reason"],
            origin_state: decision["origin_state"],
            run_id: decision["run_id"],
            decided_at: decision["decided_at"]
          },
          session_history: [],
          session_history_total_count: 0
        }

        :sys.replace_state(pid, fn state ->
          %{
            state
            | blocked: %{issue_id => blocked_entry},
              claimed: MapSet.put(state.claimed, issue_id)
          }
        end)

        assert %{
                 reason: "reported_blocker",
                 origin_state: "In Progress",
                 run_id: "run-manual-clear",
                 decided_at: decided_at
               } =
                 Orchestrator.snapshot(orchestrator_name, 1_000).blocked
                 |> List.first()
                 |> Map.fetch!(:blocking_decision)

        assert is_binary(decided_at)

        other_issue_id = "issue-unrelated"
        unrelated_blocked = %{issue_id: other_issue_id, run_id: "run-unrelated"}
        unrelated_retry = %{timer_ref: nil, attempt: 1}

        :sys.replace_state(pid, fn state ->
          %{
            state
            | blocked: Map.put(state.blocked, other_issue_id, unrelated_blocked),
              claimed: state.claimed |> MapSet.put(issue_id) |> MapSet.put(other_issue_id),
              retry_attempts: %{
                issue_id => %{timer_ref: nil, attempt: 2},
                other_issue_id => unrelated_retry
              },
              failure_counts: %{issue_id => 3, other_issue_id => 1}
          }
        end)

        assert %{status: "cleared", issue_identifier: identifier} =
                 Orchestrator.clear_blocking_decision(identifier, orchestrator_name)

        state = :sys.get_state(pid)
        assert state.blocked == %{other_issue_id => unrelated_blocked}
        assert state.claimed == MapSet.new([other_issue_id])
        assert state.retry_attempts == %{other_issue_id => unrelated_retry}
        assert state.failure_counts == %{other_issue_id => 1}

        persisted_issue = FakePersistence.get_issue_by_identifier(identifier)
        assert persisted_issue.blocking_decision == nil
        assert persisted_issue.no_progress_streak == 0
        assert persisted_issue.snapshot == %{"state" => "Blocked"}
        assert FakePersistence.list_runs_for_issue(identifier) == [persisted_run]

        assert %{status: "already_cleared", issue_identifier: identifier} =
                 Orchestrator.clear_blocking_decision(identifier, orchestrator_name)
      end

      test "orchestrator snapshot reflects last codex update and session id" do
        issue_id = "issue-snapshot"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-188",
          title: "Snapshot test",
          description: "Capture codex state",
          state: "In Progress",
          url: "https://example.org/issues/MT-188"
        }

        orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        started_at = DateTime.utc_now()

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          turn_count: 0,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: started_at
        }

        state_with_issue =
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

        :sys.replace_state(pid, fn _ -> state_with_issue end)

        now = DateTime.utc_now()

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :session_started,
             session_id: "thread-live-turn-live",
             timestamp: now
           }}
        )

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{method: "some-event"},
             timestamp: now
           }}
        )

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{
               "method" => "item/tool/call",
               "params" => %{"tool" => "linear_task_read"}
             },
             timestamp: now
           }}
        )

        snapshot = GenServer.call(pid, :snapshot)
        assert %{running: [snapshot_entry]} = snapshot
        assert snapshot_entry.issue_id == issue_id
        assert snapshot_entry.session_id == "thread-live-turn-live"
        assert snapshot_entry.turn_count == 1
        assert snapshot_entry.last_codex_timestamp == now

        assert snapshot_entry.last_codex_message == %{
                 event: :notification,
                 message: %{
                   "method" => "item/tool/call",
                   "params" => %{"tool" => "linear_task_read"}
                 },
                 timestamp: now
               }

        assert Enum.any?(snapshot_entry.session_history, fn history_event ->
                 history_event.event == :notification and history_event.detail == "some-event"
               end)

        assert Enum.any?(snapshot_entry.session_history, fn history_event ->
                 history_event.event == :notification and
                   history_event.detail == "dynamic tool call requested (linear_task_read)"
               end)

        assert snapshot_entry.session_history_total_count == 3
      end

      test "orchestrator persists codex update payload or raw when message is absent" do
        issue_id = "issue-persist-codex"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-PERSIST-CODEX",
          title: "Persist codex",
          state: "In Progress"
        }

        pid = Process.whereis(Orchestrator)
        initial_state = :sys.get_state(pid)

        on_exit(fn -> restore_process_state_if_alive(pid, initial_state) end)

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          run_id: "run-persist-codex",
          session_id: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          turn_count: 0,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: DateTime.utc_now()
        }

        state_with_issue =
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

        :sys.replace_state(pid, fn _ -> state_with_issue end)

        now = DateTime.utc_now()

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{
               "method" => "item/tool/call",
               "params" => %{"tool" => "linear_task_read", "api_token" => "secret-token"}
             },
             raw: "Authorization: Bearer secret-token",
             session_id: "thread-persist",
             timestamp: now
           }}
        )

        _snapshot = GenServer.call(pid, :snapshot)

        [event] = FakePersistence.list_events(run_id: "run-persist-codex", event_type: "codex.update")
        assert event.payload.event == "notification"
        assert event.payload.message["method"] == "item/tool/call"
        assert event.payload.message["params"]["api_token"] == "[REDACTED]"
        assert event.payload.debug.raw == "Authorization: [REDACTED]"
        assert event.payload.session_id == "thread-persist"
        assert event.payload.timestamp == DateTime.to_iso8601(now)
      end

      test "orchestrator coalesces adjacent streaming agent message notifications" do
        issue_id = "issue-streaming-history"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-STREAM",
          title: "Streaming history test",
          description: "Collapse streaming fragments",
          state: "In Progress",
          url: "https://example.org/issues/MT-STREAM"
        }

        orchestrator_name = Module.concat(__MODULE__, :StreamingHistoryOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        started_at = DateTime.utc_now()

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          turn_count: 0,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: started_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        first_at = DateTime.add(started_at, 1, :second)
        second_at = DateTime.add(started_at, 2, :second)
        third_at = DateTime.add(started_at, 3, :second)

        send(pid, {:codex_worker_update, issue_id, streaming_delta("I", first_at)})
        send(pid, {:codex_worker_update, issue_id, streaming_delta("’m", second_at)})
        send(pid, {:codex_worker_update, issue_id, streaming_delta("checking", third_at)})

        assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
        assert snapshot_entry.last_codex_timestamp == third_at
        assert snapshot_entry.session_history_total_count == 3
        assert length(snapshot_entry.session_history) == 1

        assert [history_event] = snapshot_entry.session_history
        assert history_event.event == :notification
        assert history_event.detail == "agent message streaming: I’m checking (3 fragments)"
        assert history_event.metadata.coalesced_event_count == 3
        assert history_event.metadata.coalesced_text == "I’m checking"
      end

      test "orchestrator records coalesced system progress in session history" do
        issue_id = "issue-system-progress"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-SYSTEM",
          title: "System progress test",
          description: "Show clone progress",
          state: "Ready",
          url: "https://example.org/issues/MT-SYSTEM"
        }

        orchestrator_name = Module.concat(__MODULE__, :SystemProgressOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        started_at = DateTime.utc_now()

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          turn_count: 0,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: started_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        send(
          pid,
          {:system_worker_update, issue_id, %{source: :system, phase: "workspace_bootstrap", operation: "git_clone", status: "running", detail: "Cloning base repository: Receiving objects: 8%"}}
        )

        send(
          pid,
          {:system_worker_update, issue_id, %{source: :system, phase: "workspace_bootstrap", operation: "git_clone", status: "running", detail: "Cloning base repository: Receiving objects: 9%"}}
        )

        assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
        assert snapshot_entry.session_history_total_count == 2
        assert [history_event] = snapshot_entry.session_history
        assert history_event.event == :system_progress
        assert history_event.source == :system
        assert history_event.label == "Git clone"
        assert history_event.detail == "Cloning base repository: Receiving objects: 9%"
        assert history_event.metadata.coalesced_event_count == 2
      end

      test "orchestrator does not coalesce streaming notifications across lifecycle events" do
        issue_id = "issue-streaming-history-boundary"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-BOUNDARY",
          title: "Streaming history boundary test",
          description: "Keep lifecycle boundaries",
          state: "In Progress",
          url: "https://example.org/issues/MT-BOUNDARY"
        }

        orchestrator_name = Module.concat(__MODULE__, :StreamingHistoryBoundaryOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        started_at = DateTime.utc_now()

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          turn_count: 0,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: started_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        first_at = DateTime.add(started_at, 1, :second)
        boundary_at = DateTime.add(started_at, 2, :second)
        second_at = DateTime.add(started_at, 3, :second)

        send(pid, {:codex_worker_update, issue_id, streaming_delta("first", first_at)})

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :tool_call_completed,
             payload: %{
               "method" => "item/tool/call",
               "params" => %{"tool" => "linear_task_read"}
             },
             timestamp: boundary_at
           }}
        )

        send(pid, {:codex_worker_update, issue_id, streaming_delta("second", second_at)})

        assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
        assert snapshot_entry.last_codex_timestamp == second_at
        assert snapshot_entry.session_history_total_count == 3

        assert Enum.map(snapshot_entry.session_history, & &1.detail) == [
                 "agent message streaming: first",
                 "dynamic tool call completed (linear_task_read)",
                 "agent message streaming: second"
               ]
      end

      test "orchestrator snapshot tracks codex thread totals and app-server pid" do
        issue_id = "issue-usage-snapshot"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-201",
          title: "Usage snapshot test",
          description: "Collect usage stats",
          state: "In Progress",
          url: "https://example.org/issues/MT-201"
        }

        orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: process_ref,
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          turn_count: 0,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: started_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        now = DateTime.utc_now()

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :session_started,
             session_id: "thread-usage-turn-usage",
             timestamp: now
           }}
        )

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{
               "method" => "thread/tokenUsage/updated",
               "params" => %{
                 "tokenUsage" => %{
                   "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
                 }
               }
             },
             timestamp: now,
             codex_app_server_pid: "4242"
           }}
        )

        snapshot = GenServer.call(pid, :snapshot)
        assert %{running: [snapshot_entry]} = snapshot
        assert snapshot_entry.codex_app_server_pid == "4242"
        assert snapshot_entry.codex_input_tokens == 12
        assert snapshot_entry.codex_output_tokens == 4
        assert snapshot_entry.codex_total_tokens == 16
        assert snapshot_entry.turn_count == 1
        assert is_integer(snapshot_entry.runtime_seconds)

        send(pid, {:DOWN, process_ref, :process, self(), :normal})
        completed_state = :sys.get_state(pid)

        assert completed_state.codex_totals.input_tokens == 12
        assert completed_state.codex_totals.output_tokens == 4
        assert completed_state.codex_totals.total_tokens == 16
        assert is_integer(completed_state.codex_totals.seconds_running)
      end

      test "orchestrator snapshot tracks turn completed usage when present" do
        issue_id = "issue-turn-completed-usage"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-202",
          title: "Turn completed usage test",
          description: "Track final turn usage",
          state: "In Progress",
          url: "https://example.org/issues/MT-202"
        }

        orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: process_ref,
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: started_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :turn_completed,
             payload: %{
               method: "turn/completed",
               usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
             },
             timestamp: DateTime.utc_now()
           }}
        )

        snapshot = GenServer.call(pid, :snapshot)
        assert %{running: [snapshot_entry]} = snapshot
        assert snapshot_entry.codex_input_tokens == 12
        assert snapshot_entry.codex_output_tokens == 4
        assert snapshot_entry.codex_total_tokens == 16

        send(pid, {:DOWN, process_ref, :process, self(), :normal})
        completed_state = :sys.get_state(pid)
        assert completed_state.codex_totals.input_tokens == 12
        assert completed_state.codex_totals.output_tokens == 4
        assert completed_state.codex_totals.total_tokens == 16
      end

      test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
        issue_id = "issue-token-count-snapshot"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-220",
          title: "Token count snapshot test",
          description: "Validate token-count style payloads",
          state: "In Progress",
          url: "https://example.org/issues/MT-220"
        }

        orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Orchestrator.RunningIssue{
          pid: self(),
          ref: process_ref,
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: started_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        now = DateTime.utc_now()

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{
               "method" => "codex/event/token_count",
               "params" => %{
                 "msg" => %{
                   "type" => "token_count",
                   "info" => %{
                     "total_token_usage" => %{
                       "input_tokens" => "2",
                       "output_tokens" => 2,
                       "total_tokens" => 4
                     }
                   }
                 }
               }
             },
             timestamp: now
           }}
        )

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{
               "method" => "codex/event/token_count",
               "params" => %{
                 "msg" => %{
                   "type" => "token_count",
                   "info" => %{
                     "total_token_usage" => %{
                       "prompt_tokens" => 10,
                       "completion_tokens" => 5,
                       "total_tokens" => 15
                     }
                   }
                 }
               }
             },
             timestamp: DateTime.utc_now()
           }}
        )

        snapshot = GenServer.call(pid, :snapshot)
        assert %{running: [snapshot_entry]} = snapshot
        assert snapshot_entry.codex_input_tokens == 10
        assert snapshot_entry.codex_output_tokens == 5
        assert snapshot_entry.codex_total_tokens == 15

        send(pid, {:DOWN, process_ref, :process, self(), :normal})
        completed_state = :sys.get_state(pid)

        assert completed_state.codex_totals.input_tokens == 10
        assert completed_state.codex_totals.output_tokens == 5
        assert completed_state.codex_totals.total_tokens == 15
      end
    end
  end
end

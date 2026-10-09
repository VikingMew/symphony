# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.OrchestratorStatus2 do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Workflow

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      import SymphonyElixir.TestSupport.RetryTimerAssertions

      test "orchestrator snapshot tracks codex rate-limit payloads" do
        issue_id = "issue-rate-limit-snapshot"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-221",
          title: "Rate limit snapshot test",
          description: "Capture codex rate limit state",
          state: "In Progress",
          url: "https://example.org/issues/MT-221"
        }

        orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
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
          project_id: "fake-project-id",
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

        rate_limits = %{
          "limit_id" => "codex",
          "primary" => %{"remaining" => 90, "limit" => 100},
          "secondary" => nil,
          "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
        }

        send(
          pid,
          {:codex_worker_update, issue_id,
           %{
             event: :notification,
             payload: %{
               "method" => "codex/event/token_count",
               "params" => %{
                 "msg" => %{
                   "type" => "event_msg",
                   "payload" => %{
                     "type" => "token_count",
                     "rate_limits" => rate_limits
                   }
                 }
               }
             },
             timestamp: DateTime.utc_now()
           }}
        )

        snapshot = GenServer.call(pid, :snapshot)
        assert snapshot.rate_limits == rate_limits
      end

      test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
        issue_id = "issue-token-precedence"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-222",
          title: "Token precedence",
          description: "Prefer per-event deltas",
          state: "In Progress",
          url: "https://example.org/issues/MT-222"
        }

        orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
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
             event: :notification,
             payload: %{
               "method" => "codex/event/token_count",
               "params" => %{
                 "msg" => %{
                   "type" => "event_msg",
                   "payload" => %{
                     "type" => "token_count",
                     "info" => %{
                       "last_token_usage" => %{
                         "input_tokens" => 2,
                         "output_tokens" => 1,
                         "total_tokens" => 3
                       },
                       "total_token_usage" => %{
                         "input_tokens" => 200,
                         "output_tokens" => 100,
                         "total_tokens" => 300
                       }
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
        assert snapshot_entry.codex_input_tokens == 200
        assert snapshot_entry.codex_output_tokens == 100
        assert snapshot_entry.codex_total_tokens == 300
      end

      test "orchestrator token accounting accumulates monotonic thread token usage totals" do
        issue_id = "issue-thread-token-usage"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-223",
          title: "Thread token usage",
          description: "Accumulate absolute thread totals",
          state: "In Progress",
          url: "https://example.org/issues/MT-223"
        }

        orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
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

        for usage <- [
              %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11},
              %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
            ] do
          send(
            pid,
            {:codex_worker_update, issue_id,
             %{
               event: :notification,
               payload: %{
                 "method" => "thread/tokenUsage/updated",
                 "params" => %{"tokenUsage" => %{"total" => usage}}
               },
               timestamp: DateTime.utc_now()
             }}
          )
        end

        snapshot = GenServer.call(pid, :snapshot)
        assert %{running: [snapshot_entry]} = snapshot
        assert snapshot_entry.codex_input_tokens == 10
        assert snapshot_entry.codex_output_tokens == 4
        assert snapshot_entry.codex_total_tokens == 14
      end

      test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
        issue_id = "issue-last-token-ignored"

        issue = %Issue{
          id: issue_id,
          identifier: "MT-224",
          title: "Last token ignored",
          description: "Ignore delta-only token reports",
          state: "In Progress",
          url: "https://example.org/issues/MT-224"
        }

        orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
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
             event: :notification,
             payload: %{
               "method" => "codex/event/token_count",
               "params" => %{
                 "msg" => %{
                   "type" => "event_msg",
                   "payload" => %{
                     "type" => "token_count",
                     "info" => %{
                       "last_token_usage" => %{
                         "input_tokens" => 8,
                         "output_tokens" => 3,
                         "total_tokens" => 11
                       }
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
        assert snapshot_entry.codex_input_tokens == 0
        assert snapshot_entry.codex_output_tokens == 0
        assert snapshot_entry.codex_total_tokens == 0
      end

      test "orchestrator snapshot includes retry backoff entries" do
        orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        retry_entry = %{
          attempt: 2,
          timer_ref: nil,
          due_at_ms: System.monotonic_time(:millisecond) + 5_000,
          identifier: "MT-500",
          error: "agent exited: :boom"
        }

        initial_state = :sys.get_state(pid)
        new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
        :sys.replace_state(pid, fn _ -> new_state end)

        snapshot = GenServer.call(pid, :snapshot)
        assert is_list(snapshot.retrying)

        assert [
                 %{
                   issue_id: "mt-500",
                   attempt: 2,
                   due_in_ms: due_in_ms,
                   identifier: "MT-500",
                   error: "agent exited: :boom"
                 }
               ] = snapshot.retrying

        assert due_in_ms > 0
      end

      test "orchestrator snapshot includes poll countdown and checking status" do
        write_workflow_file!(Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        now_ms = System.monotonic_time(:millisecond)

        :sys.replace_state(pid, fn state ->
          %{
            state
            | poll_interval_ms: 30_000,
              tick_timer_ref: nil,
              tick_token: make_ref(),
              next_poll_due_at_ms: now_ms + 4_000,
              poll_check_in_progress: false
          }
        end)

        snapshot = GenServer.call(pid, :snapshot)

        assert %{
                 polling: %{
                   checking?: false,
                   poll_interval_ms: 30_000,
                   next_poll_in_ms: due_in_ms
                 }
               } = snapshot

        assert is_integer(due_in_ms)
        assert due_in_ms >= 0
        assert due_in_ms <= 4_000

        :sys.replace_state(pid, fn state ->
          %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
        end)

        snapshot = GenServer.call(pid, :snapshot)
        assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
      end

      test "orchestrator starts with listening disabled" do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: 5_000,
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        assert %{
                 polling: %{
                   listening?: false,
                   checking?: false,
                   next_poll_in_ms: next_poll_in_ms,
                   poll_interval_ms: 5_000
                 }
               } = GenServer.call(pid, :snapshot)

        assert is_integer(next_poll_in_ms)
        assert next_poll_in_ms >= 0
        assert next_poll_in_ms <= 5_000

        assert %{listening?: true} = Orchestrator.start_listening(orchestrator_name)
        assert %{polling: %{listening?: true}} = GenServer.call(pid, :snapshot)
      end

      test "public snapshot, refresh, and listening controls preserve the live state type" do
        write_workflow_file!(Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_name = Module.concat(__MODULE__, :PublicControlStateOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid), do: Process.exit(pid, :normal)
        end)

        assert %Orchestrator.State{} = :sys.get_state(pid)
        assert %{polling: %{listening?: false}} = Orchestrator.snapshot(orchestrator_name, 1_000)
        assert %Orchestrator.State{} = :sys.get_state(pid)
        assert %{listening?: true} = Orchestrator.start_listening(orchestrator_name)
        assert %Orchestrator.State{} = :sys.get_state(pid)
        assert %{listening?: true} = Orchestrator.start_refine_only_listening(orchestrator_name)
        assert %Orchestrator.State{} = :sys.get_state(pid)
        assert %{queued: _} = Orchestrator.request_refresh(orchestrator_name)
        assert %Orchestrator.State{} = :sys.get_state(pid)
        assert %{listening?: false} = Orchestrator.stop_listening(orchestrator_name)
        assert %Orchestrator.State{} = :sys.get_state(pid)
      end

      test "orchestrator poll cycle resets next refresh countdown after a check" do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: 50
        )

        orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        :sys.replace_state(pid, fn state ->
          %{
            state
            | poll_interval_ms: 50,
              poll_check_in_progress: true,
              next_poll_due_at_ms: nil
          }
        end)

        send(pid, :run_poll_cycle)

        snapshot =
          wait_for_snapshot(pid, fn
            %{polling: %{checking?: false, poll_interval_ms: 50, next_poll_in_ms: next_poll_in_ms}}
            when is_integer(next_poll_in_ms) and next_poll_in_ms <= 50 ->
              true

            _ ->
              false
          end)

        assert %{
                 polling: %{
                   checking?: false,
                   poll_interval_ms: 50,
                   next_poll_in_ms: next_poll_in_ms
                 }
               } = snapshot

        assert is_integer(next_poll_in_ms)
        assert next_poll_in_ms >= 0
        assert next_poll_in_ms <= 50
      end

      test "orchestrator restarts stalled workers with retry backoff" do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          codex_stall_timeout_ms: 1_000,
          project_repository_url: "git@example.com:org/repo.git"
        )

        use_noop_linear_client()

        issue_id = "issue-stall"
        orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        worker_pid =
          spawn(fn ->
            receive do
              :done -> :ok
            end
          end)

        stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
        initial_state = :sys.get_state(pid)

        running_entry = %Orchestrator.RunningIssue{
          pid: worker_pid,
          ref: make_ref(),
          identifier: "MT-STALL",
          issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
          session_id: "thread-stall-turn-stall",
          last_codex_message: nil,
          last_codex_timestamp: stale_activity_at,
          last_codex_event: :notification,
          admission: %{workspace_authority: {:panel_local}},
          started_at: stale_activity_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
          |> Map.put(:listening_mode, :listening_all)
        end)

        trace_retry_timers(pid)

        {state, log} =
          with_log(fn ->
            monitor = Process.monitor(worker_pid)
            send(pid, :run_poll_cycle)
            assert_receive {:DOWN, ^monitor, :process, ^worker_pid, _reason}
            eventually(fn -> not Map.has_key?(:sys.get_state(pid).running, issue_id) end)
            :sys.get_state(pid)
          end)

        assert Process.alive?(worker_pid) == false
        assert Map.has_key?(state.running, issue_id) == false

        assert %{
                 attempt: 1,
                 due_at_ms: due_at_ms,
                 identifier: "MT-STALL",
                 error: "budget_exhausted",
                 failure_evidence: %{"elapsed_ms" => elapsed_ms, "timeout_ms" => 1_000}
               } = state.retry_attempts[issue_id]

        assert elapsed_ms > 1_000
        assert is_integer(due_at_ms)
        assert log =~ "in 10000ms (attempt 1)"
        assert_retry_delay(pid, issue_id, state.retry_attempts[issue_id], 10_000)
      end

      test "orchestrator blocks input-required agent results without scheduling retry" do
        issue_id = "issue-input-blocked"
        orchestrator_name = Module.concat(__MODULE__, :InputBlockedOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        ref = make_ref()
        initial_state = :sys.get_state(pid)

        FakePersistence.put_issues([
          %{
            identifier: "MT-BLOCK",
            tracker_issue_id: issue_id,
            state: "In Progress",
            blocking_decision: nil,
            no_progress_streak: 0
          }
        ])

        worker_pid = spawn(fn -> Process.sleep(:infinity) end)

        running_entry = %Orchestrator.RunningIssue{
          pid: worker_pid,
          ref: ref,
          run_id: "run-input-blocked",
          identifier: "MT-BLOCK",
          issue: %Issue{id: issue_id, identifier: "MT-BLOCK", state: "In Progress"},
          session_id: "thread-block",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: DateTime.utc_now(),
          session_history: [],
          session_history_total_count: 0,
          agent_result:
            {:blocked,
             %{
               reason: "blocked_on_push_auth",
               detail: %{"action" => "refresh GitHub credentials"},
               references: %{"remote" => "origin"}
             }}
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        send(pid, {:DOWN, ref, :process, self(), :normal})
        state = :sys.get_state(pid)

        assert Map.has_key?(state.running, issue_id) == false
        assert MapSet.member?(state.claimed, issue_id)
        assert state.retry_attempts == %{}
        assert %{reason: "runtime_failure", detail: detail} = state.blocked[issue_id]
        assert detail["reason"] == "blocked_on_push_auth"
        assert detail["detail"] == %{"action" => "refresh GitHub credentials"}

        snapshot = GenServer.call(pid, :snapshot)
        assert [%{issue_id: ^issue_id, reason: "runtime_failure"}] = snapshot.blocked
      end
    end
  end
end

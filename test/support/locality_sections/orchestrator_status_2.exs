# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.OrchestratorStatusTest.Sections.OrchestratorStatus2 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      alias SymphonyElixir.Codex.MessageHumanizer

      import ExUnit.CaptureLog
      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Health
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.TestSupport.FakePersistence
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Worker.HeartbeatMetrics
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          ensure_panel_children_running!: 0,
          panel_supervisor_running?: 0,
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      alias SymphonyElixir.OrchestratorStatusTest.RollbackLinearClient

      test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
        issue_id = "issue-token-count-snapshot"

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-220",
          title: "Token count snapshot test",
          description: "Validate token-count style payloads",
          state: "In Progress",
          url: "https://example.org/issues/MT-220"
        }

        orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
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

      test "orchestrator snapshot tracks codex rate-limit payloads" do
        issue_id = "issue-rate-limit-snapshot"

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-221",
          title: "Rate limit snapshot test",
          description: "Capture codex rate limit state",
          state: "In Progress",
          url: "https://example.org/issues/MT-221"
        }

        orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
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

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-222",
          title: "Token precedence",
          description: "Prefer per-event deltas",
          state: "In Progress",
          url: "https://example.org/issues/MT-222"
        }

        orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
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

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-223",
          title: "Thread token usage",
          description: "Accumulate absolute thread totals",
          state: "In Progress",
          url: "https://example.org/issues/MT-223"
        }

        orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
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

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-224",
          title: "Last token ignored",
          description: "Ignore delta-only token reports",
          state: "In Progress",
          url: "https://example.org/issues/MT-224"
        }

        orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        process_ref = make_ref()
        started_at = DateTime.utc_now()

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
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
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        retry_entry = %{
          attempt: 2,
          timer_ref: nil,
          due_at_ms: System.monotonic_time(:millisecond) + 5000,
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
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

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
              next_poll_due_at_ms: now_ms + 4000,
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
        assert due_in_ms <= 4000

        :sys.replace_state(pid, fn state ->
          %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
        end)

        snapshot = GenServer.call(pid, :snapshot)
        assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
      end

      test "orchestrator starts with listening disabled" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: 5000,
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

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
                   poll_interval_ms: 5000
                 }
               } = GenServer.call(pid, :snapshot)

        assert is_integer(next_poll_in_ms)
        assert next_poll_in_ms >= 0
        assert next_poll_in_ms <= 5000

        assert %{listening?: true} =
                 Elixir.SymphonyElixir.Orchestrator.start_listening(orchestrator_name)

        assert %{polling: %{listening?: true}} = GenServer.call(pid, :snapshot)
      end

      test "public snapshot, refresh, and listening controls preserve the live state type" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_name = Module.concat(__MODULE__, :PublicControlStateOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(pid)

        assert %{polling: %{listening?: false}} =
                 Elixir.SymphonyElixir.Orchestrator.snapshot(orchestrator_name, 1000)

        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(pid)

        assert %{listening?: true} =
                 Elixir.SymphonyElixir.Orchestrator.start_listening(orchestrator_name)

        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(pid)

        assert %{listening?: true} =
                 Elixir.SymphonyElixir.Orchestrator.start_refine_only_listening(orchestrator_name)

        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(pid)
        assert %{queued: _} = Elixir.SymphonyElixir.Orchestrator.request_refresh(orchestrator_name)
        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(pid)

        assert %{listening?: false} =
                 Elixir.SymphonyElixir.Orchestrator.stop_listening(orchestrator_name)

        assert %Elixir.SymphonyElixir.Orchestrator.State{} = :sys.get_state(pid)
      end

      test "orchestrator poll cycle resets next refresh countdown after a check" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: nil,
          poll_interval_ms: 50
        )

        orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

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
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: nil,
          codex_stall_timeout_ms: 1000,
          project_repository_url: "git@example.com:org/repo.git"
        )

        use_noop_linear_client()

        issue_id = "issue-stall"
        orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

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

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
          pid: worker_pid,
          ref: make_ref(),
          identifier: "MT-STALL",
          issue: %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: "MT-STALL",
            state: "In Progress"
          },
          session_id: "thread-stall-turn-stall",
          last_codex_message: nil,
          last_codex_timestamp: stale_activity_at,
          last_codex_event: :notification,
          started_at: stale_activity_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
          |> Map.put(:listening_mode, :listening_all)
        end)

        send(pid, {:tick, initial_state.tick_token})
        Process.sleep(100)
        state = :sys.get_state(pid)

        assert Process.alive?(worker_pid) == false
        assert Map.has_key?(state.running, issue_id) == false

        assert %{
                 attempt: 1,
                 due_at_ms: due_at_ms,
                 identifier: "MT-STALL",
                 error: "stalled for " <> _
               } = state.retry_attempts[issue_id]

        assert is_integer(due_at_ms)
        remaining_ms = due_at_ms - System.monotonic_time(:millisecond)
        assert remaining_ms >= 9500
        assert remaining_ms <= 10_500
      end
    end
  end
end

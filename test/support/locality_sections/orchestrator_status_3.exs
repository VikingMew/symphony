# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.OrchestratorStatus3 do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.OrchestratorStatusTest.RollbackLinearClient
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Workflow

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      test "Codex willRetry false still consumes the existing failure budget" do
        write_workflow_file!(Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        use_noop_linear_client()
        orchestrator_name = Module.concat(__MODULE__, :CodexFailureBudgetOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid), do: Process.exit(pid, :normal)
        end)

        evidence = %{"codex_error_info" => "serverOverloaded", "turn_status" => "failed", "will_retry" => false}
        failure = SymphonyElixir.RunFailure.classify({:codex_upstream_capacity, evidence})
        initial_state = :sys.get_state(pid)

        running = fn issue_id, identifier, run_id ->
          %Orchestrator.RunningIssue{
            run_id: run_id,
            identifier: identifier,
            issue: %Issue{id: issue_id, identifier: identifier, state: "Refining"},
            project_id: "fake-project-id",
            session_id: "session-#{run_id}",
            started_at: DateTime.utc_now(),
            admission: %{workspace_authority: {:panel_local}},
            session_history: [],
            session_history_total_count: 0
          }
        end

        retry_issue_id = "issue-capacity-retry"
        retry_running = running.(retry_issue_id, "SYM-CAPACITY-RETRY", "run-capacity-retry")

        :sys.replace_state(pid, fn _state ->
          initial_state
          |> Map.put(:running, %{retry_issue_id => retry_running})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, retry_issue_id))
        end)

        Orchestrator.worker_task_finished(retry_issue_id, {:failed, failure}, pid)

        eventually(fn ->
          state = :sys.get_state(pid)
          state.failure_counts[retry_issue_id] == 1 and match?(%{attempt: 1}, state.retry_attempts[retry_issue_id])
        end)

        exhausted_issue_id = "issue-capacity-exhausted"
        exhausted_running = running.(exhausted_issue_id, "SYM-CAPACITY-EXHAUSTED", "run-capacity-exhausted")

        FakePersistence.put_issues([
          %{
            identifier: "SYM-CAPACITY-EXHAUSTED",
            tracker_issue_id: exhausted_issue_id,
            state: "Refining",
            blocking_decision: nil,
            no_progress_streak: 0
          }
        ])

        :sys.replace_state(pid, fn state ->
          %{
            state
            | running: Map.put(state.running, exhausted_issue_id, exhausted_running),
              claimed: MapSet.put(state.claimed, exhausted_issue_id),
              failure_counts: Map.put(state.failure_counts, exhausted_issue_id, 3)
          }
        end)

        Orchestrator.worker_task_finished(exhausted_issue_id, {:failed, failure}, pid)

        eventually(fn -> Map.has_key?(:sys.get_state(pid).blocked, exhausted_issue_id) end)
        exhausted = :sys.get_state(pid)
        assert exhausted.failure_counts[exhausted_issue_id] == nil
        assert exhausted.blocked[exhausted_issue_id].reason == "budget_exhausted"
        assert exhausted.blocked[exhausted_issue_id].detail["cause"] == "codex_upstream_capacity"
        assert exhausted.blocked[exhausted_issue_id].detail["cause_evidence"]["will_retry"] == false
      end

      test "missing refinement completion blocks the Refining issue through the existing decision path" do
        write_workflow_file!(Workflow.workflow_file_path(),
          project_repository_url: "git@example.com:org/repo.git"
        )

        use_noop_linear_client()
        orchestrator_name = Module.concat(__MODULE__, :MissingRefinementCompletionOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid), do: Process.exit(pid, :normal)
        end)

        issue_id = "issue-refinement-completion"
        identifier = "SYM-REFINEMENT-COMPLETION"

        FakePersistence.put_issues([
          %{
            identifier: identifier,
            tracker_issue_id: issue_id,
            state: "Refining",
            blocking_decision: nil,
            no_progress_streak: 0
          }
        ])

        running = %Orchestrator.RunningIssue{
          run_id: "run-refinement-completion",
          identifier: identifier,
          issue: %Issue{id: issue_id, identifier: identifier, state: "Refining"},
          project_id: "fake-project-id",
          session_id: "session-refinement-completion",
          started_at: DateTime.utc_now(),
          session_history: [],
          session_history_total_count: 0
        }

        initial_state = :sys.get_state(pid)

        :sys.replace_state(pid, fn _state ->
          initial_state
          |> Map.put(:running, %{issue_id => running})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
        end)

        detail = %{
          "missing" => ["linear_task_update(target_state: Needs Refinement Review)"],
          "reason" => "missing_refinement_completion"
        }

        summary = %{
          "phase" => "validation",
          "outcome" => "blocked",
          "reason" => "handoff_failed",
          "detail" => Jason.encode!(%{"detail" => detail, "reason" => ["handoff_failed", "missing_refinement_completion"]})
        }

        failure = SymphonyElixir.RunFailure.from_worker_summary("task.failed", summary)
        Orchestrator.worker_task_finished(issue_id, {:blocked, failure}, pid)

        eventually(fn -> Map.has_key?(:sys.get_state(pid).blocked, issue_id) end)

        blocked = :sys.get_state(pid).blocked[issue_id]
        assert blocked.state == "Blocked"
        assert blocked.reason == "contract_violation"
        assert blocked.detail["reason"] == "handoff_failed"

        decision = FakePersistence.get_issue_by_identifier(identifier).blocking_decision
        assert decision["run_id"] == running.run_id
        assert decision["origin_state"] == "Refining"
        assert decision["transition_status"] == "completed"
      end

      test "stalled sessions consume the failure budget without inspecting protocol events" do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          codex_stall_timeout_ms: 1_000,
          project_repository_url: "git@example.com:org/repo.git"
        )

        use_noop_linear_client()

        issue_id = "issue-stall-input-blocked"
        orchestrator_name = Module.concat(__MODULE__, :StallInputBlockedOrchestrator)
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
          identifier: "MT-STALL-BLOCK",
          issue: %Issue{id: issue_id, identifier: "MT-STALL-BLOCK", state: "In Progress"},
          session_id: "thread-stall-block",
          last_codex_message: %{"method" => "turn/input_required", "params" => %{"reason" => "operator decision"}},
          last_codex_timestamp: stale_activity_at,
          last_codex_event: :turn_input_required,
          admission: %{workspace_authority: {:panel_local}},
          started_at: stale_activity_at,
          session_history: [],
          session_history_total_count: 0
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
          |> Map.put(:listening_mode, :listening_all)
        end)

        {state, _log} =
          with_log(fn ->
            monitor = Process.monitor(worker_pid)
            send(pid, :run_poll_cycle)
            assert_receive {:DOWN, ^monitor, :process, ^worker_pid, _reason}
            eventually(fn -> not Map.has_key?(:sys.get_state(pid).running, issue_id) end)
            :sys.get_state(pid)
          end)

        assert Process.alive?(worker_pid) == false
        assert Map.has_key?(state.running, issue_id) == false
        assert MapSet.member?(state.claimed, issue_id)
        assert %{attempt: 1} = state.retry_attempts[issue_id]
        assert state.failure_counts[issue_id] == 1
        assert Map.has_key?(state.blocked, issue_id) == false
      end

      test "orchestrator does not treat pre-codex workspace preparation as codex stall" do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_api_token: nil,
          codex_stall_timeout_ms: 1_000
        )

        issue_id = "issue-workspace-preparing"
        orchestrator_name = Module.concat(__MODULE__, :PreCodexStallOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        worker_pid =
          spawn(fn ->
            receive do
              :done -> :ok
            end
          end)

        on_exit(fn ->
          if Process.alive?(worker_pid) do
            send(worker_pid, :done)
          end

          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        started_at = DateTime.add(DateTime.utc_now(), -5, :second)
        initial_state = :sys.get_state(pid)

        running_entry = %Orchestrator.RunningIssue{
          pid: worker_pid,
          ref: make_ref(),
          identifier: "MT-PRE-CODEX",
          issue: %Issue{id: issue_id, identifier: "MT-PRE-CODEX", state: "In Progress"},
          session_id: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: started_at
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
          |> Map.put(:listening_mode, :listening_all)
        end)

        send(pid, :run_poll_cycle)
        state = :sys.get_state(pid)

        assert Process.alive?(worker_pid)
        assert Map.has_key?(state.running, issue_id)
        assert Map.has_key?(state.retry_attempts, issue_id) == false
      end

      test "force stop reports a typed no-active task cancellation result" do
        :sys.replace_state(Orchestrator, fn state ->
          %{state | running: %{}, claimed: MapSet.new(), retry_attempts: %{}}
        end)

        cancellation = %{cancelled: 0, failed: [], project_id: nil, status: "no_active_assignment", tasks: []}

        assert %{cancelled_tasks: ^cancellation} = Orchestrator.force_stop_all()
        assert [event] = FakePersistence.list_events(event_type: "orchestrator.force_stop_all")
        assert event.payload.cancelled_tasks == cancellation
      end

      test "cancel current facade leaves listening mode unchanged" do
        orchestrator_name = Module.concat(__MODULE__, :CancelCurrentNoActiveOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        :sys.replace_state(pid, fn state -> %{state | listening_mode: :listening_all} end)

        assert %{
                 listening?: true,
                 listening_mode: "listening_all",
                 cancelled_tasks: %{status: "no_active_assignment", cancelled: 0, failed: [], tasks: [], project_id: nil}
               } = Orchestrator.cancel_current_task(orchestrator_name)

        assert :sys.get_state(pid).listening_mode == :listening_all
      end

      test "force stop all agents disables listening and rolls back symphony-owned state when unchanged" do
        previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
        previous_test_pid = Application.get_env(:symphony_elixir, :rollback_linear_test_pid)
        previous_linear_state = Application.get_env(:symphony_elixir, :rollback_linear_state)

        Application.put_env(:symphony_elixir, :linear_client_module, RollbackLinearClient)
        Application.put_env(:symphony_elixir, :rollback_linear_test_pid, self())
        Application.put_env(:symphony_elixir, :rollback_linear_state, "In Progress")

        orchestrator_name = Module.concat(__MODULE__, :ForceStopRollbackOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          restore_app_env(:linear_client_module, previous_linear_client)
          restore_app_env(:rollback_linear_test_pid, previous_test_pid)
          restore_app_env(:rollback_linear_state, previous_linear_state)

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

        issue_id = "issue-rollback"
        issue = %Issue{id: issue_id, identifier: "MT-ROLLBACK", state: "In Progress", title: "Rollback"}

        running_entry = %Orchestrator.RunningIssue{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          linear_state_transitions: [
            %{
              from_state: "Ready",
              to_state: "In Progress",
              rollback_to_state: "Ready",
              source: :symphony_backend
            }
          ]
        }

        :sys.replace_state(pid, fn state ->
          state
          |> Map.put(:listening_mode, :listening_all)
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.put(state.claimed, issue_id))
        end)

        assert %{listening?: false, rollback_results: [%{status: "rolled_back"}]} =
                 Orchestrator.force_stop_all(orchestrator_name)

        assert_receive {:fetch_issue_states_by_ids, [^issue_id]}
        assert_receive {:resolve_state, ^issue_id, "Ready"}
        assert_receive {:update_issue_state_id, ^issue_id, "state-ready"}
        assert Process.alive?(worker_pid) == false
        assert %{polling: %{listening?: false}, running: []} = GenServer.call(pid, :snapshot)
      end

      test "force stop skips rollback when Linear state changed externally" do
        previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
        previous_test_pid = Application.get_env(:symphony_elixir, :rollback_linear_test_pid)
        previous_linear_state = Application.get_env(:symphony_elixir, :rollback_linear_state)

        Application.put_env(:symphony_elixir, :linear_client_module, RollbackLinearClient)
        Application.put_env(:symphony_elixir, :rollback_linear_test_pid, self())
        Application.put_env(:symphony_elixir, :rollback_linear_state, "Ready to Merge")

        orchestrator_name = Module.concat(__MODULE__, :ForceStopSkipRollbackOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          restore_app_env(:linear_client_module, previous_linear_client)
          restore_app_env(:rollback_linear_test_pid, previous_test_pid)
          restore_app_env(:rollback_linear_state, previous_linear_state)

          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        issue_id = "issue-skip-rollback"
        issue = %Issue{id: issue_id, identifier: "MT-SKIP", state: "In Progress", title: "Skip rollback"}

        worker_pid =
          spawn(fn ->
            receive do
              :done -> :ok
            end
          end)

        :sys.replace_state(pid, fn state ->
          Map.put(state, :running, %{
            issue_id => %Orchestrator.RunningIssue{
              pid: worker_pid,
              ref: make_ref(),
              identifier: issue.identifier,
              issue: issue,
              started_at: DateTime.utc_now(),
              linear_state_transitions: [%{from_state: "Ready", to_state: "In Progress", rollback_to_state: "Ready"}]
            }
          })
        end)

        assert %{rollback_results: [%{status: "skipped", reason: "linear_state_changed"}]} =
                 Orchestrator.force_stop_all(orchestrator_name)

        assert_receive {:fetch_issue_states_by_ids, [^issue_id]}
        refute_receive {:update_issue_state_id, ^issue_id, _state_id}, 100
      end

      test "status dashboard logs offline status through Logger" do
        log =
          capture_log(fn ->
            assert :ok = StatusDashboard.render_offline_status()
          end)

        assert log =~ "Symphony application offline"
      end

      test "status dashboard snapshot formatter stays silent" do
        snapshot_data =
          {:ok,
           %{
             running: [],
             retrying: [],
             codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
             rate_limits: nil
           }}

        rendered = StatusDashboard.format_snapshot_content(snapshot_data, 0.0)

        assert rendered == ""
      end

      test "status dashboard does not log polling countdown or checking marker" do
        waiting_snapshot =
          {:ok,
           %{
             running: [],
             retrying: [],
             codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
             rate_limits: nil,
             polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
           }}

        waiting_rendered = StatusDashboard.format_snapshot_content(waiting_snapshot, 0.0)
        assert waiting_rendered == ""

        checking_snapshot =
          {:ok,
           %{
             running: [],
             retrying: [],
             codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
             rate_limits: nil,
             polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
           }}

        checking_rendered = StatusDashboard.format_snapshot_content(checking_snapshot, 0.0)
        assert checking_rendered == ""
      end

      test "status dashboard does not log empty running or retry state" do
        snapshot_data =
          {:ok,
           %{
             running: [],
             retrying: [],
             codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
             rate_limits: nil
           }}

        rendered = StatusDashboard.format_snapshot_content(snapshot_data, 0.0)
        plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

        assert plain == ""
      end

      test "status dashboard does not render running agent status rows" do
        snapshot_data =
          {:ok,
           %{
             running: [
               %{
                 identifier: "MT-777",
                 state: "running",
                 session_id: "thread-1234567890",
                 codex_app_server_pid: "4242",
                 codex_total_tokens: 3_200,
                 runtime_seconds: 75,
                 turn_count: 7,
                 last_codex_event: "turn_completed",
                 last_codex_message: %{
                   event: :notification,
                   message: %{
                     "method" => "turn/completed",
                     "params" => %{"turn" => %{"status" => "completed"}}
                   }
                 }
               }
             ],
             retrying: [],
             codex_totals: %{
               input_tokens: 90,
               output_tokens: 12,
               total_tokens: 102,
               seconds_running: 75
             },
             rate_limits: nil
           }}

        assert StatusDashboard.format_snapshot_content(snapshot_data, 0.0) == ""
      end

      test "status dashboard does not render terminal border chrome" do
        snapshot_data =
          {:ok,
           %{
             running: [],
             retrying: [],
             codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
             rate_limits: nil
           }}

        rendered = StatusDashboard.format_snapshot_content(snapshot_data, 0.0)

        assert rendered == ""
      end

      test "status dashboard notify_update does not render terminal output" do
        dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
        orchestrator_pid = Process.whereis(Orchestrator)

        on_exit(&restart_orchestrator_if_stopped/0)

        if is_pid(orchestrator_pid) do
          assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Orchestrator)
        end

        {:ok, pid} =
          StatusDashboard.start_link(
            name: dashboard_name,
            enabled: true,
            refresh_ms: 60_000,
            render_interval_ms: 16
          )

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        output =
          ExUnit.CaptureIO.capture_io(fn ->
            StatusDashboard.notify_update(dashboard_name)
            :sys.get_state(pid)
          end)

        assert output == ""

        log =
          capture_log(fn ->
            StatusDashboard.notify_update(dashboard_name)
            :sys.get_state(pid)
          end)

        assert log == ""

        :sys.replace_state(pid, fn state ->
          %{state | last_snapshot_fingerprint: :force_next_change}
        end)
      end

      test "status dashboard repeated snapshot refreshes preserve Orchestrator state" do
        orchestrator_pid = Process.whereis(Orchestrator)
        dashboard_name = Module.concat(__MODULE__, :RepeatedSnapshotDashboard)

        {:ok, dashboard_pid} =
          StatusDashboard.start_link(
            name: dashboard_name,
            enabled: true,
            refresh_ms: 60_000
          )

        on_exit(fn ->
          if Process.alive?(dashboard_pid), do: Process.exit(dashboard_pid, :normal)
        end)

        assert %Orchestrator.State{} = :sys.get_state(orchestrator_pid)

        Enum.each(1..3, fn _ ->
          StatusDashboard.notify_update(dashboard_name)
          send(dashboard_pid, :tick)
        end)

        _ = :sys.get_state(dashboard_pid)
        assert %Orchestrator.State{} = :sys.get_state(orchestrator_pid)
        assert Process.alive?(orchestrator_pid)
      end
    end
  end
end

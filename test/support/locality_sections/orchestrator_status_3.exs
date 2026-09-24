# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.OrchestratorStatusTest.Sections.OrchestratorStatus3 do
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

      test "orchestrator blocks input-required agent results without scheduling retry" do
        issue_id = "issue-input-blocked"
        orchestrator_name = Module.concat(__MODULE__, :InputBlockedOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        ref = make_ref()
        initial_state = :sys.get_state(pid)

        Elixir.SymphonyElixir.TestSupport.FakePersistence.put_issues([
          %{
            identifier: "MT-BLOCK",
            tracker_issue_id: issue_id,
            blocking_decision: nil,
            no_progress_streak: 0
          }
        ])

        worker_pid = spawn(fn -> Process.sleep(:infinity) end)

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
          pid: worker_pid,
          ref: ref,
          identifier: "MT-BLOCK",
          issue: %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: "MT-BLOCK",
            state: "In Progress"
          },
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
        Process.sleep(50)

        state = :sys.get_state(pid)

        assert Map.has_key?(state.running, issue_id) == false
        assert MapSet.member?(state.claimed, issue_id)
        assert state.retry_attempts == %{}
        assert %{reason: "blocked_on_push_auth", detail: detail} = state.blocked[issue_id]
        assert detail =~ "refresh GitHub credentials"

        snapshot = GenServer.call(pid, :snapshot)
        assert [%{issue_id: ^issue_id, reason: "blocked_on_push_auth"}] = snapshot.blocked
      end

      test "stalled sessions consume the failure budget without inspecting protocol events" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: nil,
          codex_stall_timeout_ms: 1000,
          project_repository_url: "git@example.com:org/repo.git"
        )

        use_noop_linear_client()

        issue_id = "issue-stall-input-blocked"
        orchestrator_name = Module.concat(__MODULE__, :StallInputBlockedOrchestrator)
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
          identifier: "MT-STALL-BLOCK",
          issue: %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: "MT-STALL-BLOCK",
            state: "In Progress"
          },
          session_id: "thread-stall-block",
          last_codex_message: %{
            "method" => "turn/input_required",
            "params" => %{"reason" => "operator decision"}
          },
          last_codex_timestamp: stale_activity_at,
          last_codex_event: :turn_input_required,
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

        send(pid, {:tick, initial_state.tick_token})
        Process.sleep(100)
        state = :sys.get_state(pid)

        assert Process.alive?(worker_pid) == false
        assert Map.has_key?(state.running, issue_id) == false
        assert MapSet.member?(state.claimed, issue_id)
        assert %{attempt: 1} = state.retry_attempts[issue_id]
        assert state.failure_counts[issue_id] == 1
        assert Map.has_key?(state.blocked, issue_id) == false
      end

      test "orchestrator does not treat pre-codex workspace preparation as codex stall" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_api_token: nil,
          codex_stall_timeout_ms: 1000
        )

        issue_id = "issue-workspace-preparing"
        orchestrator_name = Module.concat(__MODULE__, :PreCodexStallOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

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

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
          pid: worker_pid,
          ref: make_ref(),
          identifier: "MT-PRE-CODEX",
          issue: %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: "MT-PRE-CODEX",
            state: "In Progress"
          },
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

        send(pid, {:tick, initial_state.tick_token})
        Process.sleep(100)
        state = :sys.get_state(pid)

        assert Process.alive?(worker_pid)
        assert Map.has_key?(state.running, issue_id)
        assert Map.has_key?(state.retry_attempts, issue_id) == false
      end

      test "force stop reports a typed no-active task cancellation result" do
        :sys.replace_state(Elixir.SymphonyElixir.Orchestrator, fn state ->
          %{state | running: %{}, claimed: MapSet.new(), retry_attempts: %{}}
        end)

        cancellation = %{
          cancelled: 0,
          failed: [],
          project_id: nil,
          status: "no_active_assignment",
          tasks: []
        }

        assert %{cancelled_tasks: ^cancellation} = Elixir.SymphonyElixir.Orchestrator.force_stop_all()

        assert [event] =
                 Elixir.SymphonyElixir.TestSupport.FakePersistence.list_events(event_type: "orchestrator.force_stop_all")

        assert event.payload.cancelled_tasks == cancellation
      end

      test "cancel current facade leaves listening mode unchanged" do
        orchestrator_name = Module.concat(__MODULE__, :CancelCurrentNoActiveOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        :sys.replace_state(pid, fn state -> %{state | listening_mode: :listening_all} end)

        assert %{
                 listening?: true,
                 listening_mode: "listening_all",
                 cancelled_tasks: %{
                   status: "no_active_assignment",
                   cancelled: 0,
                   failed: [],
                   tasks: [],
                   project_id: nil
                 }
               } = Elixir.SymphonyElixir.Orchestrator.cancel_current_task(orchestrator_name)

        assert :sys.get_state(pid).listening_mode == :listening_all
      end

      test "force stop all agents disables listening and rolls back symphony-owned state when unchanged" do
        previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
        previous_test_pid = Application.get_env(:symphony_elixir, :rollback_linear_test_pid)
        previous_linear_state = Application.get_env(:symphony_elixir, :rollback_linear_state)

        Application.put_env(
          :symphony_elixir,
          :linear_client_module,
          Elixir.SymphonyElixir.OrchestratorStatusTest.RollbackLinearClient
        )

        Application.put_env(:symphony_elixir, :rollback_linear_test_pid, self())
        Application.put_env(:symphony_elixir, :rollback_linear_state, "In Progress")

        orchestrator_name = Module.concat(__MODULE__, :ForceStopRollbackOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

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

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-ROLLBACK",
          state: "In Progress",
          title: "Rollback"
        }

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
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
                 Elixir.SymphonyElixir.Orchestrator.force_stop_all(orchestrator_name)

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

        Application.put_env(
          :symphony_elixir,
          :linear_client_module,
          Elixir.SymphonyElixir.OrchestratorStatusTest.RollbackLinearClient
        )

        Application.put_env(:symphony_elixir, :rollback_linear_test_pid, self())
        Application.put_env(:symphony_elixir, :rollback_linear_state, "Ready to Merge")

        orchestrator_name = Module.concat(__MODULE__, :ForceStopSkipRollbackOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          restore_app_env(:linear_client_module, previous_linear_client)
          restore_app_env(:rollback_linear_test_pid, previous_test_pid)
          restore_app_env(:rollback_linear_state, previous_linear_state)

          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        issue_id = "issue-skip-rollback"

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-SKIP",
          state: "In Progress",
          title: "Skip rollback"
        }

        worker_pid =
          spawn(fn ->
            receive do
              :done -> :ok
            end
          end)

        :sys.replace_state(pid, fn state ->
          Map.put(state, :running, %{
            issue_id => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
              pid: worker_pid,
              ref: make_ref(),
              identifier: issue.identifier,
              issue: issue,
              started_at: DateTime.utc_now(),
              linear_state_transitions: [
                %{from_state: "Ready", to_state: "In Progress", rollback_to_state: "Ready"}
              ]
            }
          })
        end)

        assert %{rollback_results: [%{status: "skipped", reason: "linear_state_changed"}]} =
                 Elixir.SymphonyElixir.Orchestrator.force_stop_all(orchestrator_name)

        assert_receive {:fetch_issue_states_by_ids, [^issue_id]}
        refute_receive {:update_issue_state_id, ^issue_id, _state_id}, 100
      end

      test "status dashboard logs offline status through Logger" do
        log =
          capture_log(fn ->
            assert :ok = Elixir.SymphonyElixir.StatusDashboard.render_offline_status()
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

        rendered = Elixir.SymphonyElixir.StatusDashboard.format_snapshot_content(snapshot_data, 0.0)

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
             polling: %{checking?: false, next_poll_in_ms: 2000, poll_interval_ms: 30_000}
           }}

        waiting_rendered =
          Elixir.SymphonyElixir.StatusDashboard.format_snapshot_content(waiting_snapshot, 0.0)

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

        checking_rendered =
          Elixir.SymphonyElixir.StatusDashboard.format_snapshot_content(checking_snapshot, 0.0)

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

        rendered = Elixir.SymphonyElixir.StatusDashboard.format_snapshot_content(snapshot_data, 0.0)
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
                 codex_total_tokens: 3200,
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

        assert Elixir.SymphonyElixir.StatusDashboard.format_snapshot_content(snapshot_data, 0.0) == ""
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

        rendered = Elixir.SymphonyElixir.StatusDashboard.format_snapshot_content(snapshot_data, 0.0)

        assert rendered == ""
      end

      test "status dashboard notify_update does not render terminal output" do
        dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
        orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

        on_exit(&restart_orchestrator_if_stopped/0)

        if is_pid(orchestrator_pid) do
          assert :ok =
                   Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
        end

        {:ok, pid} =
          Elixir.SymphonyElixir.StatusDashboard.start_link(
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
            Elixir.SymphonyElixir.StatusDashboard.notify_update(dashboard_name)
            Process.sleep(50)
          end)

        assert output == ""

        log =
          capture_log(fn ->
            Elixir.SymphonyElixir.StatusDashboard.notify_update(dashboard_name)
            Process.sleep(50)
          end)

        assert log == ""

        :sys.replace_state(pid, fn state ->
          %{state | last_snapshot_fingerprint: :force_next_change}
        end)
      end
    end
  end
end

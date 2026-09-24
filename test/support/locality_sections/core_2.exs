# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.CoreTest.Sections.Core2 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      alias SymphonyElixir.Orchestrator.DispatchPolicy

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

      alias SymphonyElixir.CoreTest.{EmptyIssueLinearClient, NotifyingLinearClient}

      test "workflow load accepts unterminated front matter with an empty prompt" do
        workflow_path =
          Path.join(
            Path.dirname(Elixir.SymphonyElixir.Workflow.workflow_file_path()),
            "UNTERMINATED_WORKFLOW.txt"
          )

        File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

        assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
                 Elixir.SymphonyElixir.Workflow.load(workflow_path)
      end

      test "workflow load rejects non-map front matter" do
        workflow_path =
          Path.join(
            Path.dirname(Elixir.SymphonyElixir.Workflow.workflow_file_path()),
            "INVALID_FRONT_MATTER_WORKFLOW.txt"
          )

        File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

        assert {:error, :workflow_front_matter_not_a_map} =
                 Elixir.SymphonyElixir.Workflow.load(workflow_path)
      end

      test "SymphonyElixir.start_link delegates to the orchestrator" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_kind: "linear",
          poll_interval_ms: 30_000,
          project_repository_url: "git@example.com:org/repo.git"
        )

        orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

        on_exit(&restart_orchestrator_if_stopped/0)

        if is_pid(orchestrator_pid) do
          assert :ok =
                   Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
        end

        assert {:ok, pid} = SymphonyElixir.start_link()
        assert Process.whereis(SymphonyElixir.Orchestrator) == pid

        GenServer.stop(pid)
      end

      test "linear issue state reconciliation fetch with no running issues is a no-op" do
        assert {:ok, []} = Elixir.SymphonyElixir.Linear.Client.fetch_issue_states_by_ids([])
      end

      test "orchestrator starts when linear tracker configuration is incomplete" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          tracker_endpoint: "",
          tracker_api_token: nil,
          tracker_project_slug: "",
          poll_interval_ms: 30_000
        )

        orchestrator_name = Module.concat(__MODULE__, :IncompleteLinearConfigOrchestrator)

        assert {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        assert Process.alive?(pid)
        GenServer.stop(pid)
      end

      test "non-active issue state stops running agent without cleaning workspace" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
          )

        issue_id = "issue-1"
        issue_identifier = "MT-555"
        workspace = Path.join(test_root, issue_identifier)

        try do
          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: test_root,
            tracker_active_states: ["Todo", "In Progress"],
            tracker_terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
          )

          File.mkdir_p!(test_root)
          File.mkdir_p!(workspace)

          agent_pid =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          state = %Elixir.SymphonyElixir.Orchestrator.State{
            running: %{
              issue_id => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
                pid: agent_pid,
                ref: nil,
                identifier: issue_identifier,
                issue: %Elixir.SymphonyElixir.Linear.Issue{
                  id: issue_id,
                  state: "Todo",
                  identifier: issue_identifier
                },
                started_at: DateTime.utc_now()
              }
            },
            claimed: MapSet.new([issue_id]),
            codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
            retry_attempts: %{}
          }

          issue = %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "Backlog",
            title: "Queued",
            description: "Not started",
            labels: []
          }

          updated_state = Elixir.SymphonyElixir.Orchestrator.reconcile_issue_states([issue], state)

          assert Map.has_key?(updated_state.running, issue_id) == false
          assert MapSet.member?(updated_state.claimed, issue_id) == false
          assert Process.alive?(agent_pid) == false
          assert File.exists?(workspace)
        after
          File.rm_rf(test_root)
        end
      end

      test "terminal issue state stops running agent and cleans workspace" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
          )

        issue_id = "issue-2"
        issue_identifier = "MT-556"
        workspace = Path.join(test_root, issue_identifier)

        try do
          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            workspace_root: test_root,
            tracker_active_states: ["Todo", "In Progress"],
            tracker_terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
          )

          File.mkdir_p!(test_root)
          File.mkdir_p!(workspace)

          agent_pid =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          state = %Elixir.SymphonyElixir.Orchestrator.State{
            running: %{
              issue_id => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
                pid: agent_pid,
                ref: nil,
                identifier: issue_identifier,
                issue: %Elixir.SymphonyElixir.Linear.Issue{
                  id: issue_id,
                  state: "In Progress",
                  identifier: issue_identifier
                },
                started_at: DateTime.utc_now()
              }
            },
            claimed: MapSet.new([issue_id]),
            codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
            retry_attempts: %{}
          }

          issue = %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "Done",
            title: "Done",
            description: "Completed",
            labels: []
          }

          updated_state = Elixir.SymphonyElixir.Orchestrator.reconcile_issue_states([issue], state)

          assert Map.has_key?(updated_state.running, issue_id) == false
          assert MapSet.member?(updated_state.claimed, issue_id) == false
          assert Process.alive?(agent_pid) == false
          assert File.exists?(workspace) == false
        after
          File.rm_rf(test_root)
        end
      end

      test "missing running issues stop active agents without cleaning the workspace" do
        test_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
          )

        previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
        issue_id = "issue-missing"
        issue_identifier = "MT-557"

        try do
          write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
            tracker_kind: "linear",
            workspace_root: test_root,
            tracker_active_states: ["Todo", "In Progress"],
            tracker_terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"],
            poll_interval_ms: 30_000,
            project_repository_url: "git@example.com:org/repo.git"
          )

          Application.put_env(
            :symphony_elixir,
            :linear_client_module,
            Elixir.SymphonyElixir.CoreTest.EmptyIssueLinearClient
          )

          orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
          {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

          on_exit(fn ->
            restore_app_env(:linear_client_module, previous_linear_client)

            if Process.alive?(pid) do
              Process.exit(pid, :normal)
            end
          end)

          Process.sleep(50)

          assert {:ok, workspace} =
                   SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

          File.mkdir_p!(workspace)

          agent_pid =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          initial_state = :sys.get_state(pid)

          running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Elixir.SymphonyElixir.Linear.Issue{
              id: issue_id,
              state: "In Progress",
              identifier: issue_identifier
            },
            started_at: DateTime.utc_now()
          }

          :sys.replace_state(pid, fn _ ->
            initial_state
            |> Map.put(:running, %{issue_id => running_entry})
            |> Map.put(:claimed, MapSet.new([issue_id]))
            |> Map.put(:retry_attempts, %{})
            |> Map.put(:listening_mode, :listening_all)
          end)

          send(pid, {:tick, initial_state.tick_token})
          Process.sleep(100)
          state = :sys.get_state(pid)

          assert Map.has_key?(state.running, issue_id) == false
          assert MapSet.member?(state.claimed, issue_id) == false
          assert Process.alive?(agent_pid) == false
          assert File.exists?(workspace)
        after
          restore_app_env(:linear_client_module, previous_linear_client)
          File.rm_rf(test_root)
        end
      end

      test "reconcile updates running issue state for active issues" do
        issue_id = "issue-3"

        state = %Elixir.SymphonyElixir.Orchestrator.State{
          running: %{
            issue_id => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
              pid: self(),
              ref: nil,
              identifier: "MT-557",
              issue: %Elixir.SymphonyElixir.Linear.Issue{
                id: issue_id,
                identifier: "MT-557",
                state: "Todo"
              },
              started_at: DateTime.utc_now()
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-557",
          state: "In Progress",
          title: "Active state refresh",
          description: "State should be refreshed",
          labels: []
        }

        updated_state = Elixir.SymphonyElixir.Orchestrator.reconcile_issue_states([issue], state)
        updated_entry = updated_state.running[issue_id]

        assert Map.has_key?(updated_state.running, issue_id)
        assert MapSet.member?(updated_state.claimed, issue_id)
        assert updated_entry.issue.state == "In Progress"
      end

      test "reconcile stops running issue when it is reassigned away from this worker" do
        issue_id = "issue-reassigned"

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Elixir.SymphonyElixir.Orchestrator.State{
          running: %{
            issue_id => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
              pid: agent_pid,
              ref: nil,
              identifier: "MT-561",
              issue: %Elixir.SymphonyElixir.Linear.Issue{
                id: issue_id,
                identifier: "MT-561",
                state: "In Progress",
                assigned_to_worker: true
              },
              started_at: DateTime.utc_now()
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: "MT-561",
          state: "In Progress",
          title: "Reassigned active issue",
          description: "Worker should stop",
          labels: [],
          assigned_to_worker: false
        }

        updated_state = Elixir.SymphonyElixir.Orchestrator.reconcile_issue_states([issue], state)

        assert Map.has_key?(updated_state.running, issue_id) == false
        assert MapSet.member?(updated_state.claimed, issue_id) == false
        assert Process.alive?(agent_pid) == false
      end

      test "worker blocker completion releases the claim for the next Ready poll" do
        issue_id = "issue-worker-blocker"
        issue_identifier = "MT-WORKER-BLOCKER"
        orchestrator_name = Module.concat(__MODULE__, :WorkerBlockerCompletionOrchestrator)

        issue = %Elixir.SymphonyElixir.Linear.Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "Ready",
          title: "Retry blocked worker completion",
          description: "Dispatch after the blocker is resolved",
          labels: []
        }

        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        :sys.replace_state(pid, fn state ->
          %{state | claimed: MapSet.put(state.claimed, issue_id), max_concurrent_agents: 1}
        end)

        Elixir.SymphonyElixir.Orchestrator.worker_task_finished(issue_id, :success, orchestrator_name)
        state = :sys.get_state(pid)
        claimed = state.claimed
        assert MapSet.member?(claimed, issue_id) == false

        dispatch_settings = %{
          active_states: MapSet.new(["ready"]),
          terminal_states: MapSet.new(["done"]),
          refinement_states: MapSet.new(),
          listening_mode: :listening_all,
          max_concurrent_agents: 1,
          max_concurrent_agents_for_state: fn _state -> 1 end,
          workflow_executor_for_state: fn _state -> "codex_agent" end,
          human_review_state?: fn _state -> false end
        }

        assert Elixir.SymphonyElixir.Orchestrator.DispatchPolicy.should_dispatch_issue?(
                 issue,
                 state,
                 dispatch_settings
               )
      end

      test "normal worker exit schedules active-state continuation retry" do
        issue_id = "issue-resume"
        ref = make_ref()
        orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        Elixir.SymphonyElixir.TestSupport.FakePersistence.put_issues([
          %{id: issue_id, identifier: "MT-558", state: "In Progress", no_progress_streak: 0}
        ])

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
          pid: self(),
          ref: ref,
          identifier: "MT-558",
          issue: %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: "MT-558",
            state: "In Progress"
          },
          started_at: DateTime.utc_now()
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.new([issue_id]))
          |> Map.put(:retry_attempts, %{})
        end)

        scheduled_from_ms = System.monotonic_time(:millisecond)
        send(pid, {:DOWN, ref, :process, self(), :normal})
        Process.sleep(50)
        state = :sys.get_state(pid)

        assert Map.has_key?(state.running, issue_id) == false
        assert MapSet.member?(state.completed, issue_id)
        assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
        assert is_integer(due_at_ms)
        assert_due_after(due_at_ms, scheduled_from_ms, 500, 2000)
      end

      defp stop_registered_orchestrator do
        case Process.whereis(SymphonyElixir.Orchestrator) do
          pid when is_pid(pid) ->
            try do
              GenServer.stop(pid)
            catch
              :exit, {:noproc, _details} -> :ok
            end

          nil ->
            :ok
        end
      end

      test "abnormal worker exit increments retry attempt progressively" do
        issue_id = "issue-crash"
        ref = make_ref()
        orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
          pid: self(),
          ref: ref,
          identifier: "MT-559",
          retry_attempt: 2,
          issue: %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: "MT-559",
            state: "In Progress"
          },
          started_at: DateTime.utc_now()
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.new([issue_id]))
          |> Map.put(:retry_attempts, %{})
        end)

        scheduled_from_ms = System.monotonic_time(:millisecond)
        send(pid, {:DOWN, ref, :process, self(), :boom})
        Process.sleep(50)
        state = :sys.get_state(pid)

        assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent crashed: :boom"} =
                 state.retry_attempts[issue_id]

        assert_due_after(due_at_ms, scheduled_from_ms, 39_500, 40_500)
      end

      test "first abnormal worker exit waits before retrying" do
        issue_id = "issue-crash-initial"
        ref = make_ref()
        orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)

        running_entry = %Elixir.SymphonyElixir.Orchestrator.RunningIssue{
          pid: self(),
          ref: ref,
          identifier: "MT-560",
          issue: %Elixir.SymphonyElixir.Linear.Issue{
            id: issue_id,
            identifier: "MT-560",
            state: "In Progress"
          },
          started_at: DateTime.utc_now()
        }

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:running, %{issue_id => running_entry})
          |> Map.put(:claimed, MapSet.new([issue_id]))
          |> Map.put(:retry_attempts, %{})
        end)

        scheduled_from_ms = System.monotonic_time(:millisecond)
        send(pid, {:DOWN, ref, :process, self(), :boom})
        Process.sleep(50)
        state = :sys.get_state(pid)

        assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent crashed: :boom"} =
                 state.retry_attempts[issue_id]

        assert_due_after(due_at_ms, scheduled_from_ms, 9000, 10_500)
      end

      test "stale retry timer messages do not consume newer retry entries" do
        issue_id = "issue-stale-retry"
        orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
        {:ok, pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)
        current_retry_token = make_ref()
        stale_retry_token = make_ref()

        :sys.replace_state(pid, fn _ ->
          initial_state
          |> Map.put(:retry_attempts, %{
            issue_id => %{
              attempt: 2,
              timer_ref: nil,
              retry_token: current_retry_token,
              due_at_ms: System.monotonic_time(:millisecond) + 30_000,
              identifier: "MT-561",
              error: "agent exited: :boom"
            }
          })
        end)

        send(pid, {:retry_issue, issue_id, stale_retry_token})
        Process.sleep(50)

        assert %{
                 attempt: 2,
                 retry_token: ^current_retry_token,
                 identifier: "MT-561",
                 error: "agent exited: :boom"
               } = :sys.get_state(pid).retry_attempts[issue_id]
      end

      test "manual refresh coalesces repeated requests and ignores superseded ticks" do
        now_ms = System.monotonic_time(:millisecond)
        stale_tick_token = make_ref()

        state = %Elixir.SymphonyElixir.Orchestrator.State{
          poll_interval_ms: 30_000,
          max_concurrent_agents: 1,
          next_poll_due_at_ms: now_ms + 30_000,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: stale_tick_token,
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          codex_rate_limits: nil,
          listening_mode: :listening_all
        }

        assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
                 Elixir.SymphonyElixir.Orchestrator.handle_call(
                   :request_refresh,
                   {self(), make_ref()},
                   state
                 )

        assert is_reference(refreshed_state.tick_timer_ref)
        assert is_reference(refreshed_state.tick_token)
        refute refreshed_state.tick_token == stale_tick_token
        assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

        assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
                 Elixir.SymphonyElixir.Orchestrator.handle_call(
                   :request_refresh,
                   {self(), make_ref()},
                   refreshed_state
                 )

        assert coalesced_state.tick_token == refreshed_state.tick_token

        assert {:noreply, ^coalesced_state} =
                 Elixir.SymphonyElixir.Orchestrator.handle_info(
                   {:tick, stale_tick_token},
                   coalesced_state
                 )
      end

      test "dispatch policy skips full ssh hosts under the shared per-host cap" do
        state = %Elixir.SymphonyElixir.Orchestrator.State{
          running: %{
            "issue-1" => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{worker_host: "worker-a"}
          }
        }

        assert Elixir.SymphonyElixir.Orchestrator.DispatchPolicy.select_worker_host(
                 state,
                 nil,
                 worker_policy_settings(1)
               ) == "worker-b"
      end

      test "dispatch policy returns no_worker_capacity when every ssh host is full" do
        state = %Elixir.SymphonyElixir.Orchestrator.State{
          running: %{
            "issue-1" => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{worker_host: "worker-a"},
            "issue-2" => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{worker_host: "worker-b"}
          }
        }

        assert Elixir.SymphonyElixir.Orchestrator.DispatchPolicy.select_worker_host(
                 state,
                 nil,
                 worker_policy_settings(1)
               ) == :no_worker_capacity
      end

      test "dispatch policy keeps the preferred ssh host when it still has capacity" do
        state = %Elixir.SymphonyElixir.Orchestrator.State{
          running: %{
            "issue-1" => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{worker_host: "worker-a"},
            "issue-2" => %Elixir.SymphonyElixir.Orchestrator.RunningIssue{worker_host: "worker-b"}
          }
        }

        assert Elixir.SymphonyElixir.Orchestrator.DispatchPolicy.select_worker_host(
                 state,
                 "worker-a",
                 worker_policy_settings(2)
               ) == "worker-a"
      end

      defp worker_policy_settings(max_per_host) do
        %{
          ssh_hosts: ["worker-a", "worker-b"],
          max_concurrent_agents_per_host: max_per_host
        }
      end

      defp assert_due_after(due_at_ms, reference_ms, min_delay_ms, max_delay_ms) do
        delay_ms = due_at_ms - reference_ms

        assert delay_ms >= min_delay_ms
        assert delay_ms <= max_delay_ms
      end

      defp restore_app_env(key, nil) do
        Application.delete_env(:symphony_elixir, key)
      end

      defp restore_app_env(key, value) do
        Application.put_env(:symphony_elixir, key, value)
      end

      test "fetch issues by states with empty state set is a no-op" do
        assert {:ok, []} = Elixir.SymphonyElixir.Linear.Client.fetch_issues_by_states([])
      end
    end
  end
end

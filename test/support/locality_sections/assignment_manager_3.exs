# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.AssignmentManager3 do
  @moduledoc false

  alias SymphonyElixir.Config.ProjectAuthority
  alias SymphonyElixir.Config.WorkflowScopes
  alias SymphonyElixir.EnvironmentFailureCircuit
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.Events
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixir.Worker.AssignmentManagerTest.ProjectTracker
  alias SymphonyElixir.Worker.AssignmentManagerTest.Tracker
  alias SymphonyElixir.Worker.AssignmentManagerTest.Workflows
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      import ExUnit.CaptureLog

      test "restart leaves worker liveness empty until a later live request records it", context do
        ready = issue(1)
        Tracker.put([ready])
        assert {:ok, assignment} = claim(context)
        complete(context, assignment)
        stop_supervised!(AssignmentManager)

        name = Module.concat(__MODULE__, "RestartedLiveness#{System.unique_integer([:positive])}")

        {:ok, restarted} =
          AssignmentManager.start_link(
            name: name,
            tracker: Tracker,
            persistence: FakePersistence,
            workflows: Workflows,
            now: fn -> context.now end,
            failure_circuit: context.circuit,
            reconcile_interval_ms: :timer.hours(1)
          )

        Tracker.put([issue(2)])
        fetch_count = Tracker.fetch_count()
        assert AssignmentManager.available_worker_slots(restarted) == 0

        assert {:ok, {:empty, 5}, %{capacity: 0, reason: :worker_session_not_found}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   restarted
                 )

        assert Tracker.fetch_count() == fetch_count
        assert AssignmentManager.available_worker_slots(restarted) == 1

        assert {:ok, next} =
                 AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   restarted
                 )

        assert next.issue_identifier == "SYM-2"
      end

      test "empty claims follow the fixed schedule and stay below the hourly query quota", context do
        Application.put_env(:symphony_elixir, :assignment_test_workflow_count, 4)
        Tracker.put([])

        assert Enum.map(1..7, fn _ -> claim(context) end) ==
                 [
                   {:ok, {:empty, 5}},
                   {:ok, {:empty, 30}},
                   {:ok, {:empty, 30}},
                   {:ok, {:empty, 30}},
                   {:ok, {:empty, 30}},
                   {:ok, {:empty, 60}},
                   {:ok, {:empty, 60}}
                 ]

        polls_per_hour = 1 + div(3_600 - 5, 30)
        assert polls_per_hour * 4 < 2_500
      end

      test "tracker errors halt workflow traversal, back off, and recover to the first empty poll", context do
        Application.put_env(:symphony_elixir, :assignment_test_workflow_count, 4)
        Tracker.fail_fetch({:linear_api_status, 429, "limited"})

        assert {:error, {:linear_api_status, 429, "limited"}, 30} = claim(context)
        assert Tracker.fetch_count() == 1
        assert {:error, {:linear_api_status, 429, "limited"}, 60} = claim(context)
        assert Tracker.fetch_count() == 2

        Tracker.fail_fetch({:linear_api_status, 503, "down"})
        assert {:error, {:linear_api_status, 503, "down"}, 60} = claim(context)
        assert Tracker.fetch_count() == 3

        Tracker.fail_fetch({:linear_api_request, :timeout})
        assert {:error, {:linear_api_request, :timeout}, 60} = claim(context)
        assert Tracker.fetch_count() == 4

        Tracker.fail_fetch(nil)
        assert {:ok, {:empty, 5}} = claim(context)
        assert Tracker.fetch_count() == 5
      end

      test "assignment resets empty and error streaks after the installation-level candidate fetch", context do
        Tracker.put([])
        assert {:ok, {:empty, 5}} = claim(context)
        assert {:ok, {:empty, 30}} = claim(context)

        Tracker.put([issue(1)])
        assert {:ok, assignment} = claim(context)
        assert Tracker.fetch_count() == 3
        complete(context, assignment)

        Tracker.put([])
        assert {:ok, {:empty, 5}} = claim(context)
      end

      test "claim uses persisted project workflow context for prompt and correlation", context do
        start_supervised!(ProjectTracker)
        {:ok, base} = Workflow.load_example_package()
        {:ok, default_project} = FakePersistence.default_project()

        {:ok, project_b} =
          FakePersistence.update_project(default_project.id, %{
            name: "Project B",
            slug: "project-b",
            linear_project_slug: "linear-b",
            repository_url: "git@example.test:b.git",
            default_branch: "main",
            checkout_depth: 1,
            source_strategy: "clone",
            worktree_fetch: true,
            worktree_cleanup: true,
            enabled: true
          })

        {:ok, _project_b_workflow} =
          FakePersistence.import_package(
            project_b,
            workflow_markdown(base, "Shared prompt {{ issue.identifier }}"),
            "test"
          )

        {:ok, project_a} =
          FakePersistence.create_project(%{
            name: "Project A",
            slug: "project-a",
            linear_project_slug: "linear-a",
            repository_url: "git@example.test:a.git",
            enabled: true
          })

        {:ok, _instance, project_config} = WorkflowScopes.split_package(base.config, base.prompt)

        {:ok, _project_a_workflow} =
          FakePersistence.import_workflow(
            project_a,
            Workflow.to_markdown(project_config, ""),
            "test"
          )

        assert :ok = WorkflowStore.force_reload()
        assert Enum.map(WorkflowStore.list_enabled(), & &1.project_id) == [project_a.id, project_b.id]
        assert {:error, :missing_project_context} = WorkflowStore.current()

        issue_b = %{issue(78) | project_slug: "linear-b"}
        ProjectTracker.put(%{"linear-a" => [issue_b]})

        manager_name = Module.concat(__MODULE__, "PersistedManager#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(
            Supervisor.child_spec(
              {AssignmentManager,
               name: manager_name,
               tracker: ProjectTracker,
               persistence: FakePersistence,
               workflows: WorkflowStore,
               now: fn -> context.now end,
               failure_circuit: context.circuit,
               reconcile_interval_ms: :timer.hours(1)},
              id: manager_name
            )
          )

        :ok = AssignmentManager.observe_session(context.worker, context.session, manager)

        assert {:ok, assignment} =
                 AssignmentManager.claim_with_policy(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   manager
                 )

        assert ProjectTracker.fetches() == ["linear-a"]
        assert assignment.project_id == project_b.id
        assert assignment.correlation["project_id"] == project_b.id
        assert assignment.payload["source"]["repository"] == "git@example.test:b.git"
        assert assignment.payload["prompt"] =~ "Shared prompt SYM-78"
        assert assignment.payload["prompt"] =~ "Prompt A" == false
        assert assignment.payload["prompt"] =~ "Prompt B" == false

        run = FakePersistence.get_run(assignment.run_id)
        assert run.project_id == project_b.id

        persisted_issue = FakePersistence.get_issue_by_identifier(issue_b.identifier)
        assert persisted_issue.project_id == project_b.id
      end

      test "docs/spec-reliability-security.md §14.5 and docs/spec-observability.md §13.8: stub worker failures open the circuit once",
           context do
        for number <- 1..EnvironmentFailureCircuit.threshold() do
          Tracker.put([issue(number)])
          assert {:ok, assignment} = claim(context)

          assert {:ok, _event} =
                   AssignmentManager.record_event(
                     context.worker.id,
                     context.session.id,
                     assignment.id,
                     "task.failed",
                     %{
                       "correlation" => assignment.correlation,
                       "summary" => failure_summary("bwrap: No permissions to create a new namespace")
                     },
                     context.manager
                   )
        end

        [alert] = FakePersistence.list_events(event_type: EnvironmentFailureCircuit.event_type())
        assert alert.payload.triggering_fingerprint == "validation_failed"
        assert alert.payload.issue_identifiers == ["SYM-1", "SYM-2", "SYM-3"]
        assert alert.payload.distinct_issue_count == EnvironmentFailureCircuit.threshold()

        assert %{active: true, triggering_fingerprint: fingerprint} =
                 EnvironmentFailureCircuit.snapshot(context.circuit)

        Tracker.put([issue(4)])
        fetch_count = Tracker.fetch_count()

        assert {:ok, {:empty, 60}, %{reason: :environment_failure_circuit_open, failure_fingerprint: ^fingerprint}} =
                 AssignmentManager.claim_with_policy_evidence(
                   context.worker.id,
                   context.session.id,
                   %{"available_slots" => 1},
                   :listening_all,
                   1,
                   context.manager
                 )

        assert Tracker.fetch_count() == fetch_count

        assert {:ok, assignment} = claim_after_circuit_reset(context, issue(4))

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.failed",
                   %{
                     "correlation" => assignment.correlation,
                     "summary" => failure_summary("bwrap: No permissions to create a new namespace")
                   },
                   context.manager
                 )

        assert [_alert] = FakePersistence.list_events(event_type: EnvironmentFailureCircuit.event_type())
      end

      defp claim(context) do
        AssignmentManager.claim_with_policy(
          context.worker.id,
          context.session.id,
          %{"available_slots" => 1},
          :listening_all,
          1,
          context.manager
        )
      end

      defp expire_worker_liveness(context) do
        key = {context.worker.id, context.session.id}

        :sys.replace_state(context.manager, fn state ->
          update_in(state.liveness[key].last_seen_at, fn _last_seen_at ->
            DateTime.add(context.now, -31, :second)
          end)
        end)
      end

      defp old_freshness_predicate_called? do
        Enum.any?(FakePersistence.calls(), fn
          {:fresh_worker_session, _worker_id, _session_id, _opts} -> true
          _call -> false
        end)
      end

      defp start_orchestrator do
        name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
        start_supervised!({Orchestrator, name: name})
        name
      end

      defp set_listening_mode(orchestrator, listening_mode) do
        :sys.replace_state(orchestrator, &%{&1 | listening_mode: listening_mode})
      end

      defp start_manager(context, orchestrator, now) do
        name = Module.concat(__MODULE__, "ObservedManager#{System.unique_integer([:positive])}")

        manager =
          start_supervised!(
            Supervisor.child_spec(
              {AssignmentManager,
               name: name,
               tracker: Tracker,
               persistence: FakePersistence,
               workflows: Workflows,
               orchestrator: orchestrator,
               now: fn -> now end,
               failure_circuit: context.circuit,
               reconcile_interval_ms: :timer.hours(1)},
              id: name
            )
          )

        :ok = AssignmentManager.observe_session(context.worker, context.session, manager)
        manager
      end

      defp send_codex_token_progress(context, manager, assignment, input_tokens, output_tokens, total_tokens) do
        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.progress",
                   %{
                     "correlation" => assignment.correlation,
                     "phase" => "codex_update",
                     "codex" => %{
                       "event" => "notification",
                       "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
                       "payload" => %{
                         "method" => "thread/tokenUsage/updated",
                         "params" => %{
                           "tokenUsage" => %{
                             "total" => %{
                               "input_tokens" => input_tokens,
                               "output_tokens" => output_tokens,
                               "total_tokens" => total_tokens
                             }
                           }
                         }
                       },
                       "session_id" => "codex-token-session"
                     }
                   },
                   manager
                 )
      end

      defp claim_after_circuit_reset(context, issue) do
        EnvironmentFailureCircuit.reset(context.circuit)
        Tracker.put([issue])
        claim(context)
      end

      defp complete(context, assignment) do
        complete_with_manager(context, assignment, context.manager)
      end

      defp complete_with_manager(context, assignment, manager) do
        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.completed",
                   %{"correlation" => assignment.correlation, "summary" => summary("succeeded")},
                   manager
                 )
      end

      defp cancel_assignment(context, assignment) do
        cancellation = Task.async(fn -> AssignmentManager.cancel_current("operator", context.manager) end)
        assert Task.yield(cancellation, 20) == nil

        assert {:ok, %{lease_renewals: [], commands: [%{"type" => "cancel_task", "task_id" => task_id}]}} =
                 AssignmentManager.heartbeat(
                   context.worker.id,
                   context.session.id,
                   %{"active_leases" => [assignment.id]},
                   context.manager
                 )

        assert task_id == assignment.id

        assert {:ok, _event} =
                 AssignmentManager.record_event(
                   context.worker.id,
                   context.session.id,
                   assignment.id,
                   "task.cancelled",
                   %{"correlation" => assignment.correlation, "summary" => summary("cancelled")},
                   context.manager
                 )

        Task.await(cancellation)
      end

      defp issue(number) do
        workflow = Application.fetch_env!(:symphony_elixir, :assignment_test_workflow)

        %Issue{
          id: "issue-#{number}",
          identifier: "SYM-#{number}",
          title: "Issue #{number}",
          description: "Work",
          priority: number,
          state: "Ready",
          project_slug: get_in(workflow.config, ["tracker", "project_slug"]),
          branch_name: "sym-#{number}",
          blocked_by: [],
          labels: [],
          assigned_to_worker: true,
          created_at: DateTime.add(~U[2026-09-01 00:00:00Z], number, :second)
        }
      end

      defp persist_issue(issue, attrs \\ %{}) do
        issue
        |> Events.issue_attrs()
        |> Map.put(:project_id, "fake-project-id")
        |> Map.merge(attrs)
        |> FakePersistence.upsert_issue()
      end

      defp blocking_decision(reason, opts \\ []) do
        %{
          "decided_at" => "2026-09-12T04:15:33Z",
          "evidence" => "test",
          "reason" => reason,
          "run_id" => Keyword.get(opts, :run_id, "run-blocked"),
          "origin_state" => Keyword.get(opts, :origin_state, "Ready"),
          "comment_status" => "pending",
          "transition_status" => Keyword.get(opts, :transition_status, "pending")
        }
      end

      defp persist_run(identifier, id, started_at) do
        FakePersistence.create_run(%{
          id: id,
          issue_identifier: identifier,
          status: "failed",
          started_at: started_at
        })
      end

      defp summary(outcome) do
        %{
          "phase" => if(outcome == "succeeded", do: "complete", else: "validation"),
          "outcome" => outcome,
          "reason" => summary_reason(outcome),
          "occurred_at" => "2026-09-06T10:00:00Z",
          "source_revision" => "abc123",
          "runtime" => %{"image_tag" => "worker:test", "worker_source_revision" => "abc123"},
          "validation_status" => summary_validation_status(outcome),
          "gates" => []
        }
      end

      defp summary_reason("succeeded"), do: "completed"
      defp summary_reason("cancelled"), do: "cancelled"
      defp summary_reason(_outcome), do: "worker_error"

      defp summary_validation_status("succeeded"), do: "passed"
      defp summary_validation_status("cancelled"), do: "cancelled"
      defp summary_validation_status(_outcome), do: "failed"

      defp failure_summary(detail) do
        "failed"
        |> summary()
        |> Map.put("detail", detail)
      end

      defp workflow_markdown(base, prompt),
        do: Workflow.to_markdown(ProjectAuthority.strip(base.config), prompt)

      defp enable_active_state(state_name) do
        workflow = Application.fetch_env!(:symphony_elixir, :assignment_test_workflow)
        active_states = workflow.config["tracker"]["active_states"] ++ [state_name]
        Application.put_env(:symphony_elixir, :assignment_test_workflow, put_in(workflow.config["tracker"]["active_states"], active_states))
      end

      defp stringify_keys(map) do
        Map.new(map, fn {key, value} -> {to_string(key), value} end)
      end

      defp eventually(fun, attempts \\ 50)
      defp eventually(fun, 0), do: assert(fun.())

      defp eventually(fun, attempts) do
        if fun.() do
          :ok
        else
          Process.sleep(10)
          eventually(fun, attempts - 1)
        end
      end
    end
  end
end

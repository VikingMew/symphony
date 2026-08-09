defmodule SymphonyElixir.OrchestratorOperatorTasksTest do
  use SymphonyElixir.TestSupport

  defmodule FakeAgentRunner do
    def run_operator(kind, run_id, recipient, opts) do
      parent = Application.fetch_env!(:symphony_elixir, :operator_runner_test_pid)
      send(parent, {:operator_runner_started, kind, run_id, self(), Keyword.get(opts, :worker_host)})

      send(parent, {
        :operator_runner_project,
        kind,
        run_id,
        Keyword.get(opts, :project_id),
        SymphonyElixir.Config.settings!().project.repository_url
      })

      receive do
        :emit_operator_updates ->
          send(recipient, {:worker_runtime_info, run_id, %{worker_host: Keyword.get(opts, :worker_host), workspace_path: "/tmp/operator/#{run_id}"}})

          send(recipient, {
            :codex_worker_update,
            run_id,
            %{
              event: :session_started,
              session_id: "thread-#{run_id}",
              codex_app_server_pid: "app-server-1",
              timestamp: DateTime.utc_now()
            }
          })

          wait_for_finish()

        {:finish_operator_runner, result} ->
          result
      after
        1_000 ->
          :ok
      end
    end

    def run(_issue, _recipient, _opts), do: :ok

    defp wait_for_finish do
      receive do
        {:finish_operator_runner, result} -> result
      after
        1_000 -> :ok
      end
    end
  end

  setup do
    previous_runner = Application.get_env(:symphony_elixir, :agent_runner_module)
    previous_pid = Application.get_env(:symphony_elixir, :operator_runner_test_pid)

    Application.put_env(:symphony_elixir, :agent_runner_module, FakeAgentRunner)
    Application.put_env(:symphony_elixir, :operator_runner_test_pid, self())

    on_exit(fn ->
      restore_app_env(:agent_runner_module, previous_runner)
      restore_app_env(:operator_runner_test_pid, previous_pid)
    end)

    :ok
  end

  test "requesting nap starts a real monitored operator process and records runtime updates" do
    {:ok, pid} = start_operator_orchestrator(:RealNap)

    reply = GenServer.call(pid, {:request_operator_task, :nap})
    assert reply.status == "running"
    assert reply.project_id == "fake-project-id"
    run_id = reply.run_id

    assert_receive {:operator_runner_started, :nap, ^run_id, runner_pid, _worker_host}, 500
    assert_receive {:operator_runner_project, :nap, ^run_id, "fake-project-id", nil}, 500

    state = :sys.get_state(pid)
    assert %{^run_id => %Orchestrator.RunningOperator{} = running_entry} = state.running
    assert is_pid(running_entry.pid)
    assert Process.alive?(running_entry.pid)
    assert is_reference(running_entry.ref)
    assert running_entry.kind == :nap

    identity = AgentRunner.operator_task_identity(:nap, run_id)
    assert running_entry.identifier == identity.identifier
    assert running_entry.label == identity.label

    send(runner_pid, :emit_operator_updates)

    snapshot =
      wait_for_snapshot(pid, fn
        %{running: [%{workspace_path: workspace_path, session_id: session_id}]} ->
          workspace_path == "/tmp/operator/#{run_id}" and session_id == "thread-#{run_id}"

        _ ->
          false
      end)

    assert [%{codex_app_server_pid: "app-server-1", turn_count: 1}] = snapshot.running

    send(runner_pid, {:finish_operator_runner, :ok})

    completed =
      wait_for_snapshot(pid, fn snapshot ->
        snapshot.running == [] and get_in(snapshot, [:operator_tasks, :nap, :status]) == "completed"
      end)

    assert completed.operator_tasks.nap.run_id == run_id
    assert completed.operator_tasks.nap.project_id == "fake-project-id"
  end

  test "requesting nap while nap is running returns busy without starting or recording another run" do
    {:ok, pid} = start_operator_orchestrator(:RejectRunningNap)

    active = Orchestrator.request_nap(pid)
    assert active.status == "running"
    assert_receive {:operator_runner_started, :nap, active_run_id, runner_pid, _worker_host}, 500
    assert active_run_id == active.run_id

    events_before_rejection = FakePersistence.list_events()
    runs_before_rejection = Enum.count(FakePersistence.calls(), &match?({:create_run, _attrs}, &1))

    rejected = Orchestrator.request_nap(pid)

    assert rejected.status == "failed"
    assert rejected.accepted == false
    assert rejected.failure_reason == "operator_task_busy: nap run is already in progress"
    assert rejected.run_id == active.run_id
    refute_receive {:operator_runner_started, :nap, _run_id, _runner_pid, _worker_host}, 100
    assert FakePersistence.list_events() == events_before_rejection
    assert Enum.count(FakePersistence.calls(), &match?({:create_run, _attrs}, &1)) == runs_before_rejection

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.operator_tasks.nap.status == "running"
    assert snapshot.operator_tasks.nap.run_id == active.run_id

    send(runner_pid, {:finish_operator_runner, :ok})
  end

  test "requesting nap while nap is queued returns already queued without changing the queued task" do
    {:ok, pid} = start_operator_orchestrator(:RejectQueuedNap)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | codex_rate_limits: %{
            "primary" => %{
              "window_duration_mins" => 300,
              "used_percent" => 99,
              "resets_at" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()
            }
          }
      }
    end)

    queued = Orchestrator.request_nap(pid)
    assert queued.status == "queued"
    events_before_rejection = FakePersistence.list_events()

    rejected = Orchestrator.request_nap(pid)

    assert rejected.status == "failed"
    assert rejected.accepted == false
    assert rejected.failure_reason == "operator_task_already_queued: nap run is already queued"
    assert rejected.run_id == queued.run_id
    refute_receive {:operator_runner_started, :nap, _run_id, _runner_pid, _worker_host}, 100
    assert FakePersistence.list_events() == events_before_rejection

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.operator_tasks.nap.status == "queued"
    assert snapshot.operator_tasks.nap.run_id == queued.run_id
  end

  test "requesting day dreaming while nap runs is accepted independently" do
    {:ok, pid} = start_operator_orchestrator(:IndependentOperatorKinds)

    nap = Orchestrator.request_nap(pid)
    assert_receive {:operator_runner_started, :nap, nap_run_id, nap_runner_pid, _worker_host}, 500
    assert nap_run_id == nap.run_id

    day_dreaming = Orchestrator.request_day_dreaming(pid)

    assert day_dreaming.accepted == true
    assert day_dreaming.status == "queued"
    assert day_dreaming.kind == "day_dreaming"
    assert day_dreaming.project_id == "fake-project-id"

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.operator_tasks.nap.status == "running"
    assert snapshot.operator_tasks.day_dreaming.status == "queued"

    send(nap_runner_pid, {:finish_operator_runner, :ok})
  end

  test "requesting nap again after completion starts a new run" do
    {:ok, pid} = start_operator_orchestrator(:NapAfterCompletion)

    first = Orchestrator.request_nap(pid)
    assert_receive {:operator_runner_started, :nap, first_run_id, first_runner_pid, _worker_host}, 500
    assert first_run_id == first.run_id
    send(first_runner_pid, {:finish_operator_runner, :ok})

    wait_for_snapshot(pid, fn snapshot ->
      snapshot.running == [] and get_in(snapshot, [:operator_tasks, :nap, :status]) == "completed"
    end)

    second = Orchestrator.request_nap(pid)

    assert second.accepted == true
    assert second.status == "running"
    refute second.run_id == first.run_id
    assert_receive {:operator_runner_started, :nap, second_run_id, second_runner_pid, _worker_host}, 500
    assert second_run_id == second.run_id

    send(second_runner_pid, {:finish_operator_runner, :ok})
  end

  test "explicit project starts operator task in that project's workflow context" do
    project = create_project_with_workflow("Project B", "project-b", "git@github.com:org/project-b.git")
    {:ok, pid} = start_operator_orchestrator(:ExplicitProject)

    reply = Orchestrator.request_nap(pid, project.id)
    assert reply.status == "running"
    assert reply.project_id == project.id
    run_id = reply.run_id

    assert_receive {:operator_runner_started, :nap, ^run_id, runner_pid, _worker_host}, 500

    assert_receive {:operator_runner_project, :nap, ^run_id, project_id, "git@github.com:org/project-b.git"}, 500
    assert project_id == project.id

    send(runner_pid, {:finish_operator_runner, :ok})
  end

  test "missing project fails when enabled projects are ambiguous" do
    {:ok, _project} = create_project("Project B", "project-b", true)
    {:ok, pid} = start_operator_orchestrator(:AmbiguousProject)

    reply = GenServer.call(pid, {:request_operator_task, :nap})

    assert reply.status == "failed"
    assert reply.project_id == nil
    assert reply.failure_reason == "project required"
    assert reply.summary.error == "project required"
    refute_receive {:operator_runner_started, :nap, _run_id, _runner_pid, _worker_host}, 100

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.operator_tasks.nap.status == "failed"
    assert snapshot.operator_tasks.nap.failure_reason == "project required"
  end

  test "missing project fails when no project is enabled" do
    {:ok, project} = FakePersistence.default_project()
    {:ok, _disabled_project} = FakePersistence.update_project(project.id, %{enabled: false})
    :ok = WorkflowStore.force_reload()
    {:ok, pid} = start_operator_orchestrator(:NoEnabledProject)

    reply = Orchestrator.request_nap(pid)

    assert reply.status == "failed"
    assert reply.failure_reason == "project required"
    assert reply.summary.error == "project required"
    refute_receive {:operator_runner_started, :nap, _run_id, _runner_pid, _worker_host}, 100
  end

  test "unknown and disabled projects fail visibly" do
    {:ok, disabled_project} = create_project("Disabled Project", "disabled", false)
    {:ok, pid} = start_operator_orchestrator(:UnknownProject)

    unknown = GenServer.call(pid, {:request_operator_task, :nap, "missing-project"})
    assert unknown.status == "failed"
    assert unknown.failure_reason == "unknown project: missing-project"
    assert unknown.summary.error == unknown.failure_reason

    disabled = GenServer.call(pid, {:request_operator_task, :nap, disabled_project.id})
    assert disabled.status == "failed"
    assert disabled.failure_reason == "unknown project: #{disabled_project.id}"
    assert disabled.summary.error == disabled.failure_reason

    refute_receive {:operator_runner_started, :nap, _run_id, _runner_pid, _worker_host}, 100
  end

  test "project without an active workflow fails instead of queueing" do
    {:ok, project} = create_project("No Workflow", "no-workflow", true)
    {:ok, pid} = start_operator_orchestrator(:NoActiveWorkflow)

    reply = GenServer.call(pid, {:request_operator_task, :day_dreaming, project.id})

    assert reply.status == "failed"
    assert reply.project_id == project.id
    assert reply.failure_reason == "no active workflow for project: #{project.id}"
    assert reply.summary.error == reply.failure_reason
    refute_receive {:operator_runner_started, :day_dreaming, _run_id, _runner_pid, _worker_host}, 100
  end

  test "completed operator task summarizes issues created in its audit trail" do
    {:ok, pid} = start_operator_orchestrator(:NapResults)

    reply = GenServer.call(pid, {:request_operator_task, :nap})
    run_id = reply.run_id
    assert_receive {:operator_runner_started, :nap, ^run_id, runner_pid, _worker_host}, 500

    FakePersistence.put_events([
      linear_issue_create_event(run_id, "success", %{"identifier" => "CCR-10"}),
      linear_issue_create_event(run_id, "success", %{"identifier" => "CCR-11"}),
      linear_issue_create_event(run_id, "skipped"),
      linear_issue_create_event("another-run", "success", %{"identifier" => "CCR-12"})
    ])

    send(runner_pid, {:finish_operator_runner, :ok})

    completed =
      wait_for_snapshot(pid, fn snapshot ->
        snapshot.running == [] and get_in(snapshot, [:operator_tasks, :nap, :status]) == "completed"
      end)

    assert completed.operator_tasks.nap.summary == %{
             created: 2,
             skipped: 1,
             failed: 0,
             issues: [%{"identifier" => "CCR-10"}, %{"identifier" => "CCR-11"}]
           }
  end

  test "operator runner failures clear running state and mark the task failed" do
    {:ok, pid} = start_operator_orchestrator(:FailedNap)

    reply = GenServer.call(pid, {:request_operator_task, :nap})
    run_id = reply.run_id
    assert_receive {:operator_runner_started, :nap, ^run_id, runner_pid, _worker_host}, 500

    send(runner_pid, {:finish_operator_runner, {:error, {:codex_startup_failed, %{reason: :boom}}}})

    snapshot =
      wait_for_snapshot(pid, fn snapshot ->
        snapshot.running == [] and get_in(snapshot, [:operator_tasks, :nap, :status]) == "failed"
      end)

    assert snapshot.operator_tasks.nap.failure_reason =~ "codex_startup_failed"
  end

  test "stale synthetic operator entries do not keep the runtime busy forever" do
    {:ok, pid} = start_operator_orchestrator(:StaleOperator)

    stale_run_id = "operator-nap-stale"

    :sys.replace_state(pid, fn state ->
      stale_entry = %Orchestrator.RunningOperator{
        kind: :nap,
        profile: "nap",
        label: "Nap",
        pid: nil,
        ref: nil,
        run_id: stale_run_id,
        identifier: nil,
        issue_id: nil,
        issue: nil,
        state: "running",
        worker_host: "local",
        workspace_path: nil,
        session_id: nil,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: "operator_task.started",
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        turn_count: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now(),
        session_history: [],
        session_history_total_count: 0
      }

      %{state | running: %{stale_run_id => stale_entry}}
    end)

    reply = GenServer.call(pid, {:request_operator_task, :day_dreaming})
    assert reply.status == "running"

    assert_receive {:operator_runner_started, :day_dreaming, run_id, runner_pid, _worker_host}, 500
    refute run_id == stale_run_id

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, stale_run_id)
    assert Map.has_key?(state.running, run_id)

    send(runner_pid, {:finish_operator_runner, :ok})
  end

  test "rate-limit gate queues operator work instead of starting a session" do
    {:ok, pid} = start_operator_orchestrator(:RateLimitBlockedOperator)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | codex_rate_limits: %{
            "primary" => %{
              "window_duration_mins" => 300,
              "used_percent" => 99,
              "resets_at" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()
            }
          }
      }
    end)

    reply = GenServer.call(pid, {:request_operator_task, :nap})
    assert reply.status == "queued"
    assert reply.project_id == "fake-project-id"
    refute_receive {:operator_runner_started, :nap, _run_id, _runner_pid, _worker_host}, 100

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.running == []
    assert snapshot.rate_limit_gate.status == :blocked
    assert snapshot.operator_tasks.nap.status == "queued"
    assert snapshot.operator_tasks.nap.project_id == "fake-project-id"
  end

  defp create_project_with_workflow(name, slug, repository_url) do
    raw_workflow = FakePersistence.active_workflow_version().raw_workflow_md
    {:ok, project} = create_project(name, slug, true, repository_url)
    {:ok, _version} = FakePersistence.import_workflow(project, raw_workflow, "test")
    :ok = WorkflowStore.force_reload()
    project
  end

  defp create_project(name, slug, enabled, repository_url \\ "git@github.com:org/repo.git") do
    FakePersistence.create_project(%{
      name: name,
      slug: slug,
      linear_project_slug: slug,
      repository_url: repository_url,
      enabled: enabled
    })
  end

  defp start_operator_orchestrator(suffix) do
    orchestrator_name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {:ok, pid}
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 500) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp linear_issue_create_event(run_id, status, result \\ nil) do
    %{
      run_id: run_id,
      event_type: "linear.tool_call",
      payload: %{
        tool: "linear_issue_create",
        status: status,
        result: result
      }
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

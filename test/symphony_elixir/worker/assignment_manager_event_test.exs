defmodule SymphonyElixir.Worker.AssignmentManagerEventTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager

  defmodule ControlledEventPersistence do
    defdelegate get_event(id), to: FakePersistence

    def worker_event_transaction(fun) do
      result = FakePersistence.worker_event_transaction(fun)

      lose_reply? = Application.get_env(:symphony_elixir, :assignment_test_drop_terminal_reply, false)

      if lose_reply? and match?({:ok, {_event, :written}}, result) do
        Application.delete_env(:symphony_elixir, :assignment_test_drop_terminal_reply)
        exit(:reply_lost_after_commit)
      end

      result
    end

    defdelegate repo_available?(), to: FakePersistence
    defdelegate get_run(id), to: FakePersistence
    defdelegate update_run(run, attrs), to: FakePersistence
    defdelegate worker_lease_duration_seconds(), to: FakePersistence
    defdelegate worker_heartbeat_interval_seconds(), to: FakePersistence

    def record_event(attrs) do
      owner = Application.fetch_env!(:symphony_elixir, :assignment_test_owner)
      send(owner, {:event_write_started, self(), attrs.event_type})

      receive do
        :commit -> FakePersistence.record_event(attrs)
        :fail -> {:error, :database_unavailable}
        :crash -> exit(:writer_crashed)
      after
        10_000 -> exit(:test_writer_not_released)
      end
    end
  end

  setup do
    FakePersistence.reset!()
    now = DateTime.utc_now()
    {:ok, registration} = FakePersistence.register_worker(%{"worker_name" => "writer-test", "total_slots" => 1})
    {:ok, run} = FakePersistence.create_run(%{project_id: "fake-project-id", issue_identifier: "SYM-WRITE", status: "running", started_at: now})
    id = Ecto.UUID.generate()

    assignment = %{
      id: id,
      task_id: id,
      lease_id: id,
      project_id: run.project_id,
      run_id: run.id,
      issue: %{id: "issue-write"},
      issue_identifier: "SYM-WRITE",
      worker_id: registration.worker.id,
      session_id: registration.session.id,
      expires_at: DateTime.add(now, 60, :second),
      last_terminal_rejection: nil,
      correlation: %{"assignment_id" => id, "worker_id" => registration.worker.id, "worker_session_id" => registration.session.id}
    }

    circuit = start_supervised!({SymphonyElixir.EnvironmentFailureCircuit, name: nil})

    manager =
      start_supervised!(
        {AssignmentManager, name: nil, persistence: ControlledEventPersistence, orchestrator: self(), failure_circuit: circuit, now: fn -> now end, reconcile_interval_ms: :timer.hours(1)}
      )

    :ok = AssignmentManager.observe_session(registration.worker, registration.session, manager)
    :sys.replace_state(manager, &%{&1 | assignment: assignment})
    Application.put_env(:symphony_elixir, :assignment_test_owner, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :assignment_test_owner)
      Application.delete_env(:symphony_elixir, :assignment_test_drop_terminal_reply)
    end)

    %{manager: manager, assignment: assignment, worker: registration.worker, session: registration.session, now: now}
  end

  test "blocked event write preserves heartbeat renewals and rejects concurrent writes", context do
    assignment = controlled_assignment(context)
    payload = %{"event_id" => Ecto.UUID.generate(), "phase" => "working"}
    write = Task.async(fn -> event(context, assignment, "task.progress", payload) end)
    assert_receive {:event_write_started, writer, "task.progress"}, 500
    later = DateTime.add(context.now, 10, :second)
    :sys.replace_state(context.manager, &%{&1 | now: fn -> later end})

    heartbeat = Task.async(fn -> AssignmentManager.heartbeat(context.worker.id, context.session.id, %{"active_leases" => [assignment.id]}, context.manager, FakePersistence) end)
    assert {:ok, {:ok, %{lease_renewals: [%{lease_expires_at: expiry}]}}} = Task.yield(heartbeat, 500)
    assert expiry == DateTime.add(later, FakePersistence.worker_lease_duration_seconds(), :second)
    assert {:error, :event_write_busy} = event(context, assignment, "task.progress", payload)
    assert FakePersistence.list_events(event_type: "task.progress") == []
    send(writer, :commit)
    assert {:ok, written} = Task.await(write)
    assert AssignmentManager.current_assignment(context.manager).expires_at == expiry
    assert {:ok, ^written} = event(context, assignment, "task.progress", payload)
    assert length(FakePersistence.list_events(event_type: "task.progress")) == 1
    conflict = %{"event_id" => payload["event_id"], "summary" => summary("succeeded")}
    assert {:error, :event_id_conflict} = event(context, assignment, "task.completed", conflict)
    assert :sys.get_state(context.manager).event_task == nil
  end

  test "admitted terminal write wins over expiry and retries acknowledge the committed event", context do
    assignment = controlled_assignment(context)
    payload = %{"event_id" => Ecto.UUID.generate(), "summary" => summary("succeeded")}
    write = Task.async(fn -> event(context, assignment, "task.completed", payload) end)
    assert_receive {:event_write_started, writer, "task.completed"}, 500
    :sys.replace_state(context.manager, &%{&1 | now: fn -> DateTime.add(assignment.expires_at, 1, :second) end})
    assert {:ok, {:empty, 5}} = claim(context)
    assert FakePersistence.get_run(assignment.run_id).status == "running"
    send(writer, :commit)
    assert_receive {:event_write_started, ^writer, "run.completed"}, 500
    send(writer, :commit)
    assert {:ok, written} = Task.await(write)
    assert AssignmentManager.current_assignment(context.manager) == nil
    assert {:ok, ^written} = event(context, assignment, "task.completed", payload)
    assert FakePersistence.get_run(assignment.run_id).status == "completed"
    assert length(FakePersistence.list_events(event_type: "run.completed")) == 1
    assert FakePersistence.list_events(event_type: "task.failed") == []
    restarted = start_supervised!(%{id: :restarted_manager, start: {AssignmentManager, :start_link, [[name: nil, persistence: FakePersistence, reconcile_interval_ms: :timer.hours(1)]]}})
    assert {:ok, ^written} = event(%{context | manager: restarted}, assignment, "task.completed", payload)
    assert AssignmentManager.current_assignment(restarted) == nil
    assert {:error, :event_id_conflict} = AssignmentManager.record_event("other-worker", context.session.id, assignment.id, "task.completed", payload, restarted)
    assert {:error, :event_id_conflict} = event(context, assignment, "task.progress", payload)
  end

  test "uncertain terminal commit is replayed before overdue assignment can expire", context do
    assignment = controlled_assignment(context)
    Application.put_env(:symphony_elixir, :assignment_test_drop_terminal_reply, true)
    payload = %{"event_id" => Ecto.UUID.generate(), "summary" => summary("succeeded")}
    write = Task.async(fn -> event(context, assignment, "task.completed", payload) end)
    assert_receive {:event_write_started, writer, "task.completed"}, 500
    send(writer, :commit)
    assert_receive {:event_write_started, ^writer, "run.completed"}, 500
    send(writer, :commit)
    assert {:error, {:event_write_failed, {:event_writer_exit, :reply_lost_after_commit}}} = Task.await(write)
    :sys.replace_state(context.manager, &%{&1 | now: fn -> DateTime.add(assignment.expires_at, 1, :second) end})
    assert {:ok, {:empty, 5}} = claim(context)
    assert AssignmentManager.current_assignment(context.manager).id == assignment.id
    assert_receive {:"$gen_cast", {:worker_task_finished, "issue-write", :success}}, 2_000
    assert AssignmentManager.current_assignment(context.manager) == nil
    assert FakePersistence.get_run(assignment.run_id).status == "completed"
    assert FakePersistence.list_events(event_type: "task.failed") == []
    assert length(FakePersistence.list_events(event_type: "run.completed")) == 1
    assert {:ok, _event} = event(context, assignment, "task.completed", payload)
  end

  test "progress write finishes before asynchronous expiry and expiry failures retain ownership", context do
    assignment = controlled_assignment(context)
    write = Task.async(fn -> event(context, assignment, "task.progress", %{}) end)
    assert_receive {:event_write_started, writer, "task.progress"}, 500
    :sys.replace_state(context.manager, &%{&1 | now: fn -> DateTime.add(assignment.expires_at, 1, :second) end})
    assert {:ok, {:empty, 5}} = claim(context)
    send(writer, :commit)
    assert {:ok, _event} = Task.await(write)
    assert_receive {:event_write_started, expirer, "task.failed"}, 500
    assert AssignmentManager.current_assignment(context.manager).id == assignment.id
    assert {:ok, %{lease_renewals: []}} = AssignmentManager.heartbeat(context.worker.id, context.session.id, %{"active_leases" => [assignment.id]}, context.manager, FakePersistence)
    send(expirer, :fail)
    eventually(fn -> :sys.get_state(context.manager).event_task == nil end)
    assert FakePersistence.get_run(assignment.run_id).status == "running"
    assert {:ok, {:empty, 5}} = claim(context)
    assert_receive {:event_write_started, retry, "task.failed"}, 500
    send(retry, :commit)
    assert_receive {:event_write_started, ^retry, "run.failed"}, 500
    send(retry, :commit)
    eventually(fn -> AssignmentManager.current_assignment(context.manager) == nil end)
    assert FakePersistence.get_run(assignment.run_id).failure_evidence["reason"] == "assignment_expired"
  end

  test "writer crashes return typed errors without losing the active assignment", context do
    assignment = controlled_assignment(context)
    payload = %{"event_id" => Ecto.UUID.generate()}
    write = Task.async(fn -> event(context, assignment, "task.progress", payload) end)
    assert_receive {:event_write_started, writer, "task.progress"}, 500
    send(writer, :crash)
    assert {:error, {:event_write_failed, {:event_writer_exit, :writer_crashed}}} = Task.await(write)
    assert AssignmentManager.current_assignment(context.manager).id == assignment.id
    retry = Task.async(fn -> event(context, assignment, "task.progress", payload) end)
    assert_receive {:event_write_started, next_writer, "task.progress"}, 500
    send(next_writer, :commit)
    assert {:ok, _event} = Task.await(retry)
  end

  test "event HTTP budget does not cancel an uncertain write and replay uses the same ID", context do
    assignment = controlled_assignment(context)
    payload = %{"event_id" => Ecto.UUID.generate()}
    write = Task.async(fn -> event(context, assignment, "task.progress", payload) end)
    assert_receive {:event_write_started, writer, "task.progress"}, 500
    assert {:error, :event_write_timeout} = Task.await(write, 6_000)
    assert {:ok, %{lease_renewals: [_renewal]}} = AssignmentManager.heartbeat(context.worker.id, context.session.id, %{"active_leases" => [assignment.id]}, context.manager, FakePersistence)
    send(writer, :commit)
    eventually(fn -> :sys.get_state(context.manager).event_task == nil end)
    assert {:ok, event} = event(context, assignment, "task.progress", payload)
    assert event.id == payload["event_id"]
    assert length(FakePersistence.list_events(event_type: "task.progress")) == 1
  end

  test "worker event API returns retryable overload and requires a stable UUID", context do
    Process.register(context.manager, AssignmentManager)
    assignment = controlled_assignment(context)
    payload = %{"event_id" => Ecto.UUID.generate()}
    write = Task.async(fn -> event(context, assignment, "task.progress", payload) end)
    assert_receive {:event_write_started, writer, "task.progress"}, 500
    params = %{"worker_id" => context.worker.id, "session_id" => context.session.id, "task_id" => assignment.id, "event_type" => "task.progress", "payload" => payload}
    response = api_event(params)
    assert response.status == 503
    assert Plug.Conn.get_resp_header(response, "retry-after") == ["1"]

    assert Jason.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "worker_event_unavailable",
               "message" => "Worker event persistence is unavailable",
               "retryable" => true
             },
             "retry_after_seconds" => 1
           }

    invalid = api_event(%{params | "payload" => %{}})
    assert invalid.status == 422
    assert get_in(Jason.decode!(invalid.resp_body), ["error", "code"]) == "invalid_event_id"
    send(writer, :commit)
    assert {:ok, written} = Task.await(write)
    accepted = api_event(params)
    assert accepted.status == 202
    assert Jason.decode!(accepted.resp_body) == %{"event_id" => written.id, "accepted" => true}
  end

  defp api_event(params) do
    conn = Plug.Test.conn(:post, "/api/worker/v1/tasks/#{params["task_id"]}/events", params)
    SymphonyElixirWeb.WorkerApiController.task_event(conn, params)
  end

  defp controlled_assignment(context), do: context.assignment

  defp event(context, assignment, type, payload) do
    AssignmentManager.record_event(context.worker.id, context.session.id, assignment.id, type, payload, context.manager)
  end

  defp claim(context), do: AssignmentManager.claim_with_policy(context.worker.id, context.session.id, %{"available_slots" => 1}, :listening_all, 1, context.manager)

  defp summary("succeeded") do
    %{
      "phase" => "complete",
      "outcome" => "succeeded",
      "reason" => "completed",
      "occurred_at" => "2026-10-07T00:00:00Z",
      "source_revision" => "abc123",
      "runtime" => %{"image_tag" => "worker:test", "worker_source_revision" => "abc123"},
      "validation_status" => "passed",
      "gates" => []
    }
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

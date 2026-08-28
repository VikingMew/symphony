defmodule SymphonyElixir.Persistence.WorkerQueue do
  @moduledoc """
  Worker registration, task queue, lease, heartbeat, and worker event persistence.
  """

  import Ecto.Query

  require Logger

  alias SymphonyElixir.{Repo, RunLifecycle, WorkerResult}

  alias SymphonyElixir.Persistence.{
    EventRecord,
    IssueRecord,
    RunRecord,
    TaskLease,
    TaskRecord,
    Worker,
    WorkerSession
  }

  @worker_protocol_version "worker-api-v1"
  @worker_heartbeat_interval_seconds 10
  @worker_lease_duration_seconds 60

  @spec worker_protocol_version() :: String.t()
  def worker_protocol_version, do: @worker_protocol_version

  @spec worker_heartbeat_interval_seconds() :: pos_integer()
  def worker_heartbeat_interval_seconds, do: worker_api_config(:heartbeat_interval_seconds, @worker_heartbeat_interval_seconds)

  @spec worker_lease_duration_seconds() :: pos_integer()
  def worker_lease_duration_seconds, do: worker_api_config(:lease_duration_seconds, @worker_lease_duration_seconds)

  @spec worker_registration_token() :: String.t() | nil
  def worker_registration_token do
    worker_api_config(:registration_token, nil) || System.get_env("SYMPHONY_WORKER_REGISTRATION_TOKEN")
  end

  @spec valid_worker_registration_token?(String.t() | nil) :: boolean()
  def valid_worker_registration_token?(token) when is_binary(token) do
    configured = worker_registration_token()
    is_binary(configured) and configured != "" and Plug.Crypto.secure_compare(configured, token)
  end

  def valid_worker_registration_token?(_), do: false

  @spec register_worker(map()) :: {:ok, %{worker: Worker.t(), session: WorkerSession.t()}} | {:error, term()}
  def register_worker(attrs) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         :ok <- validate_worker_protocol(map_get(attrs, "protocol_version", :protocol_version)) do
      Repo.transaction(fn -> register_worker!(attrs) end)
    end
  end

  @spec list_workers(keyword()) :: [Worker.t()]
  def list_workers(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(w in Worker, order_by: [asc: w.name], limit: ^limit))
    else
      []
    end
  end

  @spec list_worker_sessions(keyword()) :: [WorkerSession.t()]
  def list_worker_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(s in WorkerSession, order_by: [desc: s.inserted_at], limit: ^limit))
    else
      []
    end
  end

  @spec enqueue_task(map()) :: {:ok, TaskRecord.t()} | {:error, term()}
  def enqueue_task(attrs) do
    with {:ok, _project_id} <- required_project_id(attrs),
         true <- repo_available?() || {:error, :repo_unavailable} do
      attrs =
        attrs
        |> Map.put_new(:status, "queued")
        |> Map.put_new(:priority, 0)
        |> Map.put_new(:execution_mode, "worker")
        |> Map.put_new(:required_capabilities, %{})
        |> Map.put_new(:payload, %{})
        |> Map.put_new(:queued_at, DateTime.utc_now())

      %TaskRecord{} |> TaskRecord.changeset(attrs) |> Repo.insert()
    end
  end

  @spec list_tasks(keyword()) :: [TaskRecord.t()]
  def list_tasks(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      TaskRecord
      |> maybe_filter_task_project(Keyword.get(opts, :project_id))
      |> order_by([t], desc: t.inserted_at)
      |> limit(^limit)
      |> Repo.all()
    else
      []
    end
  end

  defp maybe_filter_task_project(query, project_id) when is_binary(project_id) and project_id != "" do
    where(query, [t], t.project_id == ^project_id)
  end

  defp maybe_filter_task_project(query, _project_id), do: query

  @spec list_task_leases(keyword()) :: [TaskLease.t()]
  def list_task_leases(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    if repo_available?() do
      Repo.all(from(l in TaskLease, order_by: [desc: l.inserted_at], limit: ^limit))
    else
      []
    end
  end

  @spec claim_task(String.t(), String.t(), map()) :: {:ok, nil | map()} | {:error, term()}
  def claim_task(worker_id, session_id, attrs \\ %{}) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, worker, session} <- active_worker_session(worker_id, session_id) do
      claim_task_for_session(worker, session, attrs)
    end
  rescue
    Ecto.ConstraintError -> {:error, :lease_conflict}
    MatchError -> {:error, :lease_conflict}
  end

  @spec heartbeat(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def heartbeat(worker_id, session_id, attrs \\ %{}) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, worker, session} <- active_worker_session(worker_id, session_id) do
      Repo.transaction(fn -> heartbeat!(worker, session, attrs) end)
    end
  end

  @spec expire_stale_worker_state(keyword()) :: {non_neg_integer(), non_neg_integer()}
  def expire_stale_worker_state(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    heartbeat_timeout_seconds = Keyword.get(opts, :heartbeat_timeout_seconds, worker_heartbeat_interval_seconds() * 3)
    heartbeat_cutoff = DateTime.add(now, -heartbeat_timeout_seconds, :second)

    if repo_available?() do
      {offline_sessions, _} =
        Repo.update_all(
          from(s in WorkerSession,
            where: s.status == "online" and s.last_heartbeat_at < ^heartbeat_cutoff
          ),
          set: [status: "offline", disconnected_at: now, updated_at: now]
        )

      {expired_leases, leases} =
        Repo.update_all(
          from(l in TaskLease, where: l.status == "active" and l.expires_at < ^now, select: l.task_id),
          set: [status: "expired", released_at: now, updated_at: now]
        )

      if leases != [] do
        Repo.update_all(
          from(t in TaskRecord, where: t.id in ^leases and t.status in ["leased", "running"]),
          set: [status: "queued", updated_at: now]
        )
      end

      {offline_sessions, expired_leases}
    else
      {0, 0}
    end
  end

  @spec cancel_task(String.t(), String.t()) :: {:ok, TaskRecord.t()} | {:error, term()}
  def cancel_task(task_id, reason \\ "operator_requested") do
    if repo_available?() do
      case Repo.get(TaskRecord, task_id) do
        nil ->
          {:error, :task_not_found}

        task ->
          payload = Map.put(task.payload || %{}, "cancel_reason", reason)
          task |> TaskRecord.changeset(%{status: "cancelled", payload: payload, finished_at: DateTime.utc_now()}) |> Repo.update()
      end
    else
      {:error, :repo_unavailable}
    end
  end

  @spec requeue_task(String.t()) :: {:ok, TaskRecord.t()} | {:error, term()}
  def requeue_task(task_id) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         %TaskRecord{} = task <- Repo.get(TaskRecord, task_id) || {:error, :task_not_found} do
      Repo.transaction(fn -> requeue_task!(task) end)
    end
  end

  @spec record_worker_task_event(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, EventRecord.t()} | {:error, term()}
  def record_worker_task_event(worker_id, session_id, task_id, event_type, payload \\ %{}) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, worker, session} <- active_worker_session(worker_id, session_id),
         %TaskRecord{} = task <- Repo.get(TaskRecord, task_id) || {:error, :task_not_found},
         %TaskLease{} = lease <- active_lease_for(task.id, worker.id, session.id) || {:error, :lease_not_active},
         :ok <- reject_expired_lease(lease),
         {:ok, correlation} <- authoritative_correlation(task, lease, session),
         :ok <- validate_correlation(payload || %{}, correlation),
         {:ok, summary} <- validate_event_summary(event_type, payload || %{}) do
<<<<<<< HEAD
      Repo.transaction(fn ->
        transition_task_from_event!(task, event_type, summary)

        event_payload = build_event_payload(payload, correlation, summary)

        event =
          %EventRecord{}
          |> EventRecord.changeset(%{
            project_id: task.project_id,
            run_id: task.run_id,
            issue_identifier: task.issue_identifier,
            event_type: event_type,
            payload: event_payload,
            occurred_at: DateTime.utc_now()
          })
          |> Repo.insert!()

        log_worker_summary(event_type, correlation, summary)
        event
      end)
=======
      Repo.transaction(fn -> persist_worker_event!(task, event_type, payload, correlation, summary) end)
>>>>>>> origin/main
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_worker_event!(task, event_type, payload, correlation, summary) do
    transition_task_from_event!(task, event_type, summary)

    event_payload =
      payload
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("correlation", correlation)
      |> maybe_put_summary(summary)

    event =
      %EventRecord{}
      |> EventRecord.changeset(%{
        project_id: task.project_id,
        run_id: task.run_id,
        issue_identifier: task.issue_identifier,
        event_type: event_type,
        payload: event_payload,
        occurred_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    log_worker_summary(event_type, correlation, summary)
    event
  end

  defp worker_api_config(key, default) do
    :symphony_elixir
    |> Application.get_env(:worker_api, [])
    |> Keyword.get(key, default)
  end

  defp repo_available?, do: Process.whereis(Repo) != nil

  defp required_project_id(attrs) do
    case map_get(attrs, "project_id", :project_id) do
      project_id when is_binary(project_id) and project_id != "" -> {:ok, project_id}
      _missing -> {:error, :project_id_required}
    end
  end

  defp validate_worker_protocol(@worker_protocol_version), do: :ok
  defp validate_worker_protocol(_), do: {:error, :unsupported_protocol_version}

  defp register_worker!(attrs) do
    now = DateTime.utc_now()
    name = map_get(attrs, "worker_name", :worker_name) || map_get(attrs, "name", :name)
    labels = normalize_labels(map_get(attrs, "labels", :labels))
    capabilities = map_get(attrs, "capabilities", :capabilities) || %{}
    worker = upsert_worker!(name, labels, capabilities, now)
    session = create_worker_session!(worker, attrs, now)

    %{worker: worker, session: session}
  end

  defp upsert_worker!(name, labels, capabilities, now) do
    (Repo.get_by(Worker, name: name) || %Worker{})
    |> Worker.changeset(%{
      name: name,
      status: "online",
      labels: %{"values" => labels},
      capabilities: capabilities,
      credential_ref: credential_ref(name),
      last_seen_at: now
    })
    |> Repo.insert_or_update!()
  end

  defp create_worker_session!(worker, attrs, now) do
    %WorkerSession{}
    |> WorkerSession.changeset(%{
      worker_id: worker.id,
      protocol_version: @worker_protocol_version,
      worker_version: map_get(attrs, "worker_version", :worker_version),
      instance_id: map_get(attrs, "instance_id", :instance_id),
      connected_at: now,
      last_heartbeat_at: now,
      status: "online"
    })
    |> Repo.insert!()
  end

  defp claim_task_for_session(worker, session, attrs) do
    available_slots = map_get(attrs, "available_slots", :available_slots) || 1
    capabilities = map_get(attrs, "capabilities", :capabilities) || worker.capabilities || %{}

    labels =
      attrs
      |> map_get("labels", :labels)
      |> Kernel.||(Map.get(capabilities, "labels"))
      |> Kernel.||(worker.labels)
      |> normalize_labels()

    if available_slots < 1 do
      {:ok, nil}
    else
      Repo.transaction(fn -> claim_matching_task!(worker, session, labels, capabilities) end)
    end
  end

  defp claim_matching_task!(worker, session, labels, capabilities) do
    case next_matching_task(labels, capabilities) do
      nil -> nil
      task -> lease_task!(task, worker, session)
    end
  end

  defp next_matching_task(labels, capabilities) do
    TaskRecord
    |> where([t], t.status == "queued")
    |> order_by([t], desc: t.priority, asc: t.queued_at)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
    |> Enum.find(&capability_match?(&1.required_capabilities, labels, capabilities))
  end

  defp lease_task!(task, worker, session) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, worker_lease_duration_seconds(), :second)
    attempt = next_lease_attempt(task.id)

    {1, _rows} =
      Repo.update_all(
        from(t in TaskRecord, where: t.id == ^task.id and t.status == "queued"),
        set: [status: "leased", started_at: now, updated_at: now]
      )

    lease =
      %TaskLease{}
      |> TaskLease.changeset(%{
        task_id: task.id,
        worker_id: worker.id,
        worker_session_id: session.id,
        status: "active",
        attempt: attempt,
        acquired_at: now,
        expires_at: expires_at
      })
      |> Repo.insert!()

    task = Repo.get!(TaskRecord, task.id)
    {:ok, correlation} = authoritative_correlation(task, lease, session)
    %{task: task, lease: lease, correlation: correlation}
  end

  defp heartbeat!(worker, session, attrs) do
    now = DateTime.utc_now()
    lease_ids = map_get(attrs, "active_leases", :active_leases) || []
    expires_at = DateTime.add(now, worker_lease_duration_seconds(), :second)

    worker |> Worker.changeset(%{status: "online", last_seen_at: now}) |> Repo.update!()
    session |> WorkerSession.changeset(%{status: "online", last_heartbeat_at: now}) |> Repo.update!()

    %{
      ok: true,
      server_time: now,
      lease_renewals: renew_leases(worker.id, session.id, lease_ids, expires_at),
      commands: cancellation_commands(worker.id, session.id)
    }
  end

  defp renew_leases(worker_id, session_id, lease_ids, expires_at) do
    TaskLease
    |> where([l], l.worker_id == ^worker_id and l.worker_session_id == ^session_id and l.status == "active")
    |> where([l], l.id in ^lease_ids)
    |> Repo.all()
    |> Enum.map(fn lease ->
      lease = lease |> TaskLease.changeset(%{expires_at: expires_at}) |> Repo.update!()
      %{lease_id: lease.id, lease_expires_at: lease.expires_at}
    end)
  end

  defp requeue_task!(task) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(l in TaskLease, where: l.task_id == ^task.id and l.status == "active"),
      set: [status: "cancelled", released_at: now, updated_at: now]
    )

    task
    |> TaskRecord.changeset(%{status: "queued", started_at: nil, finished_at: nil, queued_at: now})
    |> Repo.update!()
  end

  defp active_worker_session(worker_id, session_id) do
    case {Repo.get(Worker, worker_id), Repo.get(WorkerSession, session_id)} do
      {%Worker{} = worker, %WorkerSession{worker_id: ^worker_id, status: "online"} = session} ->
        {:ok, worker, session}

      _ ->
        {:error, :worker_session_not_found}
    end
  end

  defp normalize_labels(%{"values" => labels}), do: normalize_labels(labels)
  defp normalize_labels(labels) when is_list(labels), do: Enum.map(labels, &to_string/1)
  defp normalize_labels(_), do: []

  defp capability_match?(required, labels, capabilities) do
    required_labels = normalize_labels(Map.get(required || %{}, "labels", Map.get(required || %{}, :labels, [])))
    required_sandbox = normalize_labels(Map.get(required || %{}, "sandbox", Map.get(required || %{}, :sandbox, [])))
    worker_sandbox = normalize_labels(Map.get(capabilities || %{}, "sandbox", Map.get(capabilities || %{}, :sandbox, [])))

    Enum.all?(required_labels, &(&1 in labels)) and Enum.all?(required_sandbox, &(&1 in worker_sandbox))
  end

  defp next_lease_attempt(task_id) do
    Repo.one(from(l in TaskLease, where: l.task_id == ^task_id, select: count(l.id))) + 1
  end

  defp cancellation_commands(worker_id, session_id) do
    TaskLease
    |> join(:inner, [l], t in TaskRecord, on: t.id == l.task_id)
    |> where([l, t], l.worker_id == ^worker_id and l.worker_session_id == ^session_id and l.status == "active")
    |> where([_l, t], t.status == "cancelled")
    |> select([_l, t], %{type: "cancel_task", task_id: t.id, reason: fragment("?->>'cancel_reason'", t.payload)})
    |> Repo.all()
  end

  defp active_lease_for(task_id, worker_id, session_id) do
    Repo.one(
      from(l in TaskLease,
        where:
          l.task_id == ^task_id and l.worker_id == ^worker_id and l.worker_session_id == ^session_id and
            l.status == "active",
        limit: 1
      )
    )
  end

  defp reject_expired_lease(%TaskLease{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt, do: {:error, :lease_expired}, else: :ok
  end

  defp transition_task_from_event!(task, event_type, summary) do
    now = DateTime.utc_now()
    attrs = RunLifecycle.task_event_attrs(event_type, now)
    attrs = if event_type == "task.accepted" and task.started_at, do: %{attrs | started_at: task.started_at}, else: attrs
    attrs = if summary, do: Map.put(attrs, :execution_summary, summary), else: attrs

    if attrs != %{} do
      updated_task = task |> TaskRecord.changeset(attrs) |> Repo.update!()
      transition_run_from_task_event!(updated_task, event_type, now, summary)
      release_lease_for_terminal_event!(updated_task, event_type)
    end
  end

  defp transition_run_from_task_event!(%TaskRecord{run_id: nil}, _event_type, _now, _summary), do: :ok

  defp transition_run_from_task_event!(%TaskRecord{} = task, event_type, now, summary) do
    attrs = RunLifecycle.run_event_attrs(event_type, now)
    attrs = if summary, do: Map.put(attrs, :execution_summary, summary), else: attrs

    if attrs == %{} do
      :ok
    else
      case Repo.get(RunRecord, task.run_id) do
        %RunRecord{} = run -> run |> RunRecord.changeset(attrs) |> Repo.update!()
        _ -> :ok
      end
    end
  end

  defp release_lease_for_terminal_event!(%TaskRecord{} = task, event_type)
       when event_type in ["task.completed", "task.failed", "task.cancelled"] do
    Repo.update_all(
      from(l in TaskLease, where: l.task_id == ^task.id and l.status == "active"),
      set: [status: "released", released_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )
  end

  defp release_lease_for_terminal_event!(_task, _event_type), do: :ok

  defp authoritative_correlation(task, lease, session) do
    run = if task.run_id, do: Repo.get(RunRecord, task.run_id)
    issue = if run && run.issue_id, do: Repo.get(IssueRecord, run.issue_id)

    {:ok,
     %{
       "project_id" => task.project_id,
       "run_id" => task.run_id,
       "issue_id" => issue && issue.tracker_issue_id,
       "issue_identifier" => task.issue_identifier,
       "run_attempt" => (run && run.attempt) || 0,
       "task_id" => task.id,
       "lease_id" => lease.id,
       "lease_attempt" => lease.attempt,
       "worker_session_id" => session.id
     }}
  end

  defp validate_correlation(payload, authoritative) when is_map(payload) do
    supplied = Map.get(payload, "correlation") || Map.get(payload, :correlation) || %{}

    Enum.reduce_while(authoritative, :ok, fn {key, expected}, :ok ->
      actual = Map.get(supplied, key) || Map.get(supplied, correlation_atom(key))

      if is_nil(actual) or actual == expected,
        do: {:cont, :ok},
        else: {:halt, {:error, {:correlation_mismatch, key}}}
    end)
  end

  defp correlation_atom("project_id"), do: :project_id
  defp correlation_atom("run_id"), do: :run_id
  defp correlation_atom("issue_id"), do: :issue_id
  defp correlation_atom("issue_identifier"), do: :issue_identifier
  defp correlation_atom("run_attempt"), do: :run_attempt
  defp correlation_atom("task_id"), do: :task_id
  defp correlation_atom("lease_id"), do: :lease_id
  defp correlation_atom("lease_attempt"), do: :lease_attempt
  defp correlation_atom("worker_session_id"), do: :worker_session_id

  defp validate_event_summary(event_type, payload)
       when event_type in ["task.progress", "task.completed", "task.failed", "task.cancelled"] do
    summary = Map.get(payload, "summary") || Map.get(payload, :summary)
    WorkerResult.validate(summary)
  end

  defp validate_event_summary(_event_type, _payload), do: {:ok, nil}

  defp maybe_put_summary(payload, nil), do: payload
  defp maybe_put_summary(payload, summary), do: Map.put(payload, "summary", summary)

  defp build_event_payload(payload, correlation, summary) do
    payload
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("correlation", correlation)
    |> maybe_put_summary(summary)
  end

  defp log_worker_summary(_event_type, _correlation, nil), do: :ok

  defp log_worker_summary(event_type, correlation, summary) do
    Logger.info(
      "Worker execution summary accepted" <>
        " issue_id=#{correlation["issue_id"]}" <>
        " issue_identifier=#{correlation["issue_identifier"]}" <>
        " run_id=#{correlation["run_id"]}" <>
        " task_id=#{correlation["task_id"]}" <>
        " lease_id=#{correlation["lease_id"]}" <>
        " run_attempt=#{correlation["run_attempt"]}" <>
        " lease_attempt=#{correlation["lease_attempt"]}" <>
        " session_id=#{Map.get(summary, "session_id")}" <>
        " event_type=#{event_type}" <>
        " phase=#{summary["phase"]}" <>
        " outcome=#{summary["outcome"]}" <>
        " validation_status=#{summary["validation_status"]}" <>
        " gate_count=#{length(summary["gates"])}"
    )
  end

  defp credential_ref(name) when is_binary(name) do
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
    "worker:#{digest}"
  end

  defp map_get(map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end
end

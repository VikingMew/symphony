defmodule SymphonyElixir.Persistence.WorkerRegistry do
  @moduledoc """
  Persistent worker identity and session registry.

  Assignments deliberately do not live here; the Panel assignment manager owns them in memory.
  """

  import Ecto.Query

  alias SymphonyElixir.{Config, ExecutionRequirement}
  alias SymphonyElixir.Persistence.{Worker, WorkerSession}
  alias SymphonyElixir.Repo

  @worker_protocol_version "worker-api-v1"
  @worker_heartbeat_interval_seconds 10
  @worker_lease_duration_seconds 60
  @host_probe_heartbeat_interval_seconds 5
  @host_probe_lease_duration_seconds 30
  @host_probe_id "local-host"

  @spec worker_protocol_version() :: String.t()
  def worker_protocol_version, do: @worker_protocol_version

  @spec worker_heartbeat_interval_seconds() :: pos_integer()
  def worker_heartbeat_interval_seconds,
    do: worker_api_config(:heartbeat_interval_seconds, @worker_heartbeat_interval_seconds)

  @spec worker_lease_duration_seconds() :: pos_integer()
  def worker_lease_duration_seconds,
    do: worker_api_config(:lease_duration_seconds, @worker_lease_duration_seconds)

  @spec worker_registration_token() :: String.t() | nil
  def worker_registration_token,
    do: worker_api_config(:registration_token, nil) || System.get_env("SYMPHONY_WORKER_REGISTRATION_TOKEN")

  @spec valid_worker_registration_token?(String.t() | nil) :: boolean()
  def valid_worker_registration_token?(token) when is_binary(token) do
    configured = worker_registration_token()
    is_binary(configured) and configured != "" and Plug.Crypto.secure_compare(configured, token)
  end

  def valid_worker_registration_token?(_token), do: false

  @spec register_worker(map()) :: {:ok, %{worker: Worker.t(), session: WorkerSession.t()}} | {:error, term()}
  def register_worker(attrs) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         :ok <- validate_worker_protocol(map_get(attrs, "protocol_version", :protocol_version)),
         :ok <- validate_total_slots(map_get(attrs, "total_slots", :total_slots)) do
      Repo.transaction(fn -> register_worker!(attrs) end)
    end
  end

  @spec active_worker_session(String.t(), String.t()) ::
          {:ok, Worker.t(), WorkerSession.t()} | {:error, :worker_session_not_found}
  def active_worker_session(worker_id, session_id) do
    case {Repo.get(Worker, worker_id), Repo.get(WorkerSession, session_id)} do
      {%Worker{} = worker, %WorkerSession{worker_id: ^worker_id, status: "online"} = session} ->
        {:ok, worker, session}

      _other ->
        {:error, :worker_session_not_found}
    end
  end

  @spec worker_session_identity(String.t(), String.t()) ::
          {:ok, Worker.t(), WorkerSession.t()} | {:error, :worker_session_not_found}
  def worker_session_identity(worker_id, session_id) do
    case {Repo.get(Worker, worker_id), Repo.get(WorkerSession, session_id)} do
      {%Worker{} = worker, %WorkerSession{worker_id: ^worker_id} = session} -> {:ok, worker, session}
      _other -> {:error, :worker_session_not_found}
    end
  end

  @spec fresh_worker_session(String.t(), String.t(), keyword()) ::
          {:ok, Worker.t(), WorkerSession.t()}
          | {:error, :worker_session_not_found | :worker_session_offline | :worker_session_stale}
  def fresh_worker_session(worker_id, session_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    timeout = Keyword.get(opts, :heartbeat_timeout_seconds, worker_heartbeat_interval_seconds() * 3)
    cutoff = DateTime.add(now, -timeout, :second)

    case {Repo.get(Worker, worker_id), Repo.get(WorkerSession, session_id)} do
      {%Worker{} = worker, %WorkerSession{worker_id: ^worker_id, status: "online", last_heartbeat_at: heartbeat} = session} ->
        if DateTime.compare(heartbeat, cutoff) in [:eq, :gt],
          do: {:ok, worker, session},
          else: {:error, :worker_session_stale}

      {%Worker{}, %WorkerSession{worker_id: ^worker_id}} ->
        {:error, :worker_session_offline}

      _other ->
        {:error, :worker_session_not_found}
    end
  end

  @spec heartbeat_worker(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def heartbeat_worker(worker_id, session_id) do
    with true <- repo_available?() || {:error, :repo_unavailable},
         {:ok, worker, session} <- active_worker_session(worker_id, session_id) do
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        worker |> Worker.changeset(%{status: "online", last_seen_at: now}) |> Repo.update!()
        session |> WorkerSession.changeset(%{status: "online", last_heartbeat_at: now}) |> Repo.update!()
        %{ok: true, server_time: now}
      end)
    end
  end

  @spec expire_stale_worker_sessions(keyword()) :: non_neg_integer()
  def expire_stale_worker_sessions(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    timeout = Keyword.get(opts, :heartbeat_timeout_seconds, worker_heartbeat_interval_seconds() * 3)
    cutoff = DateTime.add(now, -timeout, :second)

    if repo_available?() do
      {count, _rows} =
        Repo.update_all(
          from(s in WorkerSession, where: s.status == "online" and s.last_heartbeat_at < ^cutoff),
          set: [status: "offline", disconnected_at: now, updated_at: now]
        )

      count
    else
      0
    end
  end

  @spec list_workers(keyword()) :: [Worker.t()]
  def list_workers(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    if repo_available?(), do: Repo.all(from(w in Worker, order_by: [asc: w.name], limit: ^limit)), else: []
  end

  @spec list_worker_sessions(keyword()) :: [WorkerSession.t()]
  def list_worker_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    if repo_available?(), do: Repo.all(from(s in WorkerSession, order_by: [desc: s.inserted_at], limit: ^limit)), else: []
  end

  @spec available_worker_slots(keyword()) :: non_neg_integer()
  def available_worker_slots(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    timeout = Keyword.get(opts, :heartbeat_timeout_seconds, worker_heartbeat_interval_seconds() * 3)
    cutoff = DateTime.add(now, -timeout, :second)

    if repo_available?() do
      Repo.one(
        from(s in WorkerSession,
          where: s.status == "online" and s.last_heartbeat_at >= ^cutoff,
          select: coalesce(sum(s.total_slots), 0)
        )
      )
    else
      0
    end
  end

  defp register_worker!(attrs) do
    now = DateTime.utc_now()
    name = map_get(attrs, "worker_name", :worker_name) || map_get(attrs, "name", :name)
    labels = normalize_labels(map_get(attrs, "labels", :labels))
    registration = registration!(attrs)
    capabilities = %{"values" => registration.capabilities}

    worker =
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

    session =
      %WorkerSession{}
      |> WorkerSession.changeset(%{
        worker_id: worker.id,
        protocol_version: @worker_protocol_version,
        worker_version: map_get(attrs, "worker_version", :worker_version),
        instance_id: map_get(attrs, "instance_id", :instance_id),
        total_slots: map_get(attrs, "total_slots", :total_slots),
        execution_surface: registration.execution_surface,
        probe_id: registration.probe_id,
        capabilities: capabilities,
        capability_digest: registration.capability_digest,
        heartbeat_interval_seconds: registration.heartbeat_interval_seconds,
        lease_duration_seconds: registration.lease_duration_seconds,
        connected_at: now,
        last_heartbeat_at: now,
        status: "online"
      })
      |> Repo.insert!()

    %{worker: worker, session: session}
  end

  defp validate_worker_protocol(@worker_protocol_version), do: :ok
  defp validate_worker_protocol(_version), do: {:error, :unsupported_protocol_version}
  defp validate_total_slots(total_slots) when is_integer(total_slots) and total_slots > 0, do: :ok
  defp validate_total_slots(_total_slots), do: {:error, :invalid_total_slots}
  defp normalize_labels(%{"values" => labels}), do: normalize_labels(labels)
  defp normalize_labels(labels) when is_list(labels), do: Enum.map(labels, &to_string/1)
  defp normalize_labels(_labels), do: []
  defp repo_available?, do: Process.whereis(Repo) != nil
  defp worker_api_config(key, default), do: Application.get_env(:symphony_elixir, :worker_api, []) |> Keyword.get(key, default)
  defp map_get(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)

  defp registration!(attrs) do
    case registration(attrs) do
      {:ok, registration} -> registration
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp registration(attrs) do
    case map_get(attrs, "execution_surface", :execution_surface) || "container_worker" do
      "container_worker" ->
        {:ok,
         %{
           execution_surface: "container_worker",
           probe_id: nil,
           capabilities: [],
           capability_digest: nil,
           heartbeat_interval_seconds: worker_heartbeat_interval_seconds(),
           lease_duration_seconds: worker_lease_duration_seconds()
         }}

      "host_probe" ->
        host_probe_registration(attrs)

      _surface ->
        {:error, :invalid_execution_surface}
    end
  end

  defp host_probe_registration(attrs) do
    policy = Config.host_probe_policy()
    probe_id = map_get(attrs, "probe_id", :probe_id)

    with true <- policy.enabled || {:error, :host_probe_disabled},
         true <- probe_id == @host_probe_id || {:error, :invalid_host_probe_id},
         1 <- map_get(attrs, "total_slots", :total_slots) || {:error, :invalid_total_slots},
         {:ok, capabilities} <- ExecutionRequirement.normalize_capabilities(map_get(attrs, "capabilities", :capabilities) || []) do
      {:ok,
       %{
         execution_surface: "host_probe",
         probe_id: probe_id,
         capabilities: capabilities,
         capability_digest: ExecutionRequirement.capability_digest(capabilities),
         heartbeat_interval_seconds: @host_probe_heartbeat_interval_seconds,
         lease_duration_seconds: @host_probe_lease_duration_seconds
       }}
    else
      {:error, reason} -> {:error, reason}
      _value -> {:error, :invalid_total_slots}
    end
  end

  defp credential_ref(name) when is_binary(name) do
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
    "worker:#{digest}"
  end
end

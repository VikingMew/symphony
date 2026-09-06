defmodule SymphonyElixir.Persistence.WorkerRegistry do
  @moduledoc """
  Persistent worker identity and session registry.

  Assignments deliberately do not live here; the Panel assignment manager owns them in memory.
  """

  import Ecto.Query

  alias SymphonyElixir.Repo
  alias SymphonyElixir.Persistence.{Worker, WorkerSession}

  @worker_protocol_version "worker-api-v1"
  @worker_heartbeat_interval_seconds 10
  @worker_lease_duration_seconds 60

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
    capabilities = map_get(attrs, "capabilities", :capabilities) || %{}

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

  defp credential_ref(name) when is_binary(name) do
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
    "worker:#{digest}"
  end
end

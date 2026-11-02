defmodule SymphonyElixir.Persistence.WorkerSession do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "worker_sessions" do
    belongs_to(:worker, SymphonyElixir.Persistence.Worker)
    field(:protocol_version, :string)
    field(:worker_version, :string)
    field(:instance_id, :string)
    field(:total_slots, :integer)
    field(:execution_surface, :string, default: "container_worker")
    field(:probe_id, :string)
    field(:capabilities, :map, default: %{"values" => []})
    field(:capability_digest, :string)
    field(:heartbeat_interval_seconds, :integer, default: 10)
    field(:lease_duration_seconds, :integer, default: 60)
    field(:connected_at, :utc_datetime_usec)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:disconnected_at, :utc_datetime_usec)
    field(:status, :string, default: "online")
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :worker_id,
      :protocol_version,
      :worker_version,
      :instance_id,
      :total_slots,
      :execution_surface,
      :probe_id,
      :capabilities,
      :capability_digest,
      :heartbeat_interval_seconds,
      :lease_duration_seconds,
      :connected_at,
      :last_heartbeat_at,
      :disconnected_at,
      :status
    ])
    |> validate_required([
      :worker_id,
      :protocol_version,
      :total_slots,
      :execution_surface,
      :capabilities,
      :heartbeat_interval_seconds,
      :lease_duration_seconds,
      :connected_at,
      :status
    ])
    |> validate_number(:total_slots, greater_than: 0)
    |> validate_number(:heartbeat_interval_seconds, greater_than: 0)
    |> validate_number(:lease_duration_seconds, greater_than: 0)
    |> validate_inclusion(:execution_surface, ["container_worker", "host_probe"])
    |> validate_inclusion(:status, ["online", "offline", "closed"])
  end
end

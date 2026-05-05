defmodule SymphonyElixir.Persistence.WorkerSession do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "worker_sessions" do
    belongs_to(:worker, SymphonyElixir.Persistence.Worker)
    field(:protocol_version, :string)
    field(:worker_version, :string)
    field(:instance_id, :string)
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
      :connected_at,
      :last_heartbeat_at,
      :disconnected_at,
      :status
    ])
    |> validate_required([:worker_id, :protocol_version, :connected_at, :status])
    |> validate_inclusion(:status, ["online", "offline", "closed"])
  end
end

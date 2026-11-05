defmodule SymphonyElixir.Persistence.WorkerSession do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.ExecutionRequirement

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
    |> validate_host_probe_identity()
  end

  defp validate_host_probe_identity(changeset) do
    if get_field(changeset, :execution_surface) == "host_probe" do
      changeset
      |> validate_required([:probe_id, :capability_digest])
      |> validate_inclusion(:probe_id, ["local-host"])
      |> validate_number(:total_slots, equal_to: 1)
      |> validate_number(:heartbeat_interval_seconds, equal_to: 5)
      |> validate_number(:lease_duration_seconds, equal_to: 30)
      |> validate_capability_evidence()
    else
      changeset
    end
  end

  defp validate_capability_evidence(changeset) do
    capabilities = get_field(changeset, :capabilities)

    case ExecutionRequirement.normalize_capabilities(capabilities) do
      {:ok, values} ->
        if get_field(changeset, :capability_digest) == ExecutionRequirement.capability_digest(values),
          do: changeset,
          else: add_error(changeset, :capability_digest, "must match capabilities")

      {:error, _reason} ->
        add_error(changeset, :capabilities, "must contain only allowlisted host-probe capabilities")
    end
  end
end

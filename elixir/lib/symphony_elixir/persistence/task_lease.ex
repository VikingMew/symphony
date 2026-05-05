defmodule SymphonyElixir.Persistence.TaskLease do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_leases" do
    belongs_to(:task, SymphonyElixir.Persistence.TaskRecord)
    belongs_to(:worker, SymphonyElixir.Persistence.Worker)
    belongs_to(:worker_session, SymphonyElixir.Persistence.WorkerSession)
    field(:status, :string, default: "active")
    field(:attempt, :integer, default: 1)
    field(:expires_at, :utc_datetime_usec)
    field(:acquired_at, :utc_datetime_usec)
    field(:released_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :task_id,
      :worker_id,
      :worker_session_id,
      :status,
      :attempt,
      :expires_at,
      :acquired_at,
      :released_at
    ])
    |> validate_required([:task_id, :worker_id, :worker_session_id, :status, :attempt, :expires_at, :acquired_at])
    |> validate_inclusion(:status, ["active", "released", "expired", "cancelled"])
    |> unique_constraint(:task_id)
  end
end

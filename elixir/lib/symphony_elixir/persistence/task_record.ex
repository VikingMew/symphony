defmodule SymphonyElixir.Persistence.TaskRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tasks" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    belongs_to(:run, SymphonyElixir.Persistence.RunRecord)
    belongs_to(:workflow_version, SymphonyElixir.Persistence.WorkflowVersion)
    field(:issue_identifier, :string)
    field(:status, :string, default: "queued")
    field(:priority, :integer, default: 0)
    field(:execution_mode, :string, default: "worker")
    field(:required_capabilities, :map, default: %{})
    field(:payload, :map, default: %{})
    field(:queued_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :project_id,
      :run_id,
      :workflow_version_id,
      :issue_identifier,
      :status,
      :priority,
      :execution_mode,
      :required_capabilities,
      :payload,
      :queued_at,
      :started_at,
      :finished_at
    ])
    |> validate_required([:status, :priority, :execution_mode, :queued_at])
    |> validate_inclusion(:status, ["queued", "leased", "running", "completed", "failed", "cancelled", "expired"])
    |> validate_inclusion(:execution_mode, ["worker", "centralized"])
  end
end

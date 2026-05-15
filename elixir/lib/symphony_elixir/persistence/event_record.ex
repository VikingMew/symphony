defmodule SymphonyElixir.Persistence.EventRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "events" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    belongs_to(:run, SymphonyElixir.Persistence.RunRecord)
    field(:issue_identifier, :string)
    field(:event_type, :string)
    field(:payload, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:project_id, :run_id, :issue_identifier, :event_type, :payload, :occurred_at])
    |> validate_required([:event_type, :occurred_at])
  end
end

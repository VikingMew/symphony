defmodule SymphonyElixir.Persistence.Worker do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "workers" do
    field(:name, :string)
    field(:status, :string, default: "offline")
    field(:labels, :map, default: %{"values" => []})
    field(:capabilities, :map, default: %{})
    field(:credential_ref, :string)
    field(:last_seen_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [:name, :status, :labels, :capabilities, :credential_ref, :last_seen_at])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, ["online", "offline", "disabled"])
    |> unique_constraint(:name)
  end
end

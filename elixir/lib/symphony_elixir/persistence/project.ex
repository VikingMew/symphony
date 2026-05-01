defmodule SymphonyElixir.Persistence.Project do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:enabled, :boolean, default: true)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description, :enabled])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end

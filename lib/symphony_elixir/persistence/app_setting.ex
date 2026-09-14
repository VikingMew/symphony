defmodule SymphonyElixir.Persistence.AppSetting do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "app_settings" do
    field(:value, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end

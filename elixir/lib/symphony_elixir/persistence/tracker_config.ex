defmodule SymphonyElixir.Persistence.TrackerConfig do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tracker_configs" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    field(:kind, :string)
    field(:endpoint, :string)
    field(:project_slug, :string)
    field(:api_key_secret_ref, :string)
    field(:active_states, :map, default: %{"values" => []})
    field(:terminal_states, :map, default: %{"values" => []})
    field(:enabled, :boolean, default: true)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :project_id,
      :kind,
      :endpoint,
      :project_slug,
      :api_key_secret_ref,
      :active_states,
      :terminal_states,
      :enabled
    ])
    |> validate_required([:project_id, :kind, :project_slug])
    |> validate_inclusion(:kind, ["linear"])
  end
end

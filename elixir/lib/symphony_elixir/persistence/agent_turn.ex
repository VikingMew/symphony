defmodule SymphonyElixir.Persistence.AgentTurn do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_turns" do
    belongs_to(:run, SymphonyElixir.Persistence.RunRecord)
    field(:turn_index, :integer)
    field(:status, :string)
    field(:summary, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [:run_id, :turn_index, :status, :summary, :started_at, :finished_at])
    |> validate_required([:run_id, :turn_index, :status])
    |> unique_constraint([:run_id, :turn_index])
  end
end

defmodule SymphonyElixir.Persistence.IssueRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "issues" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    field(:tracker_issue_id, :string)
    field(:identifier, :string)
    field(:title, :string)
    field(:state, :string)
    field(:url, :string)
    field(:labels, :map, default: %{"values" => []})
    field(:snapshot, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:project_id, :tracker_issue_id, :identifier, :title, :state, :url, :labels, :snapshot])
    |> validate_required([:identifier])
    |> unique_constraint([:project_id, :identifier])
  end
end

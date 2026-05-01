defmodule SymphonyElixir.Persistence.WorkspaceRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspaces" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    field(:issue_identifier, :string)
    field(:path, :string)
    field(:host, :string)
    field(:status, :string, default: "active")
    field(:created_at, :utc_datetime_usec)
    field(:cleaned_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:project_id, :issue_identifier, :path, :host, :status, :created_at, :cleaned_at])
    |> validate_required([:issue_identifier, :path, :status])
  end
end

defmodule SymphonyElixir.Persistence.WorkflowVersion do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_versions" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    field(:version, :integer)
    field(:raw_workflow_md, :string)
    field(:yaml_config, :map, default: %{})
    field(:prompt_body, :string)
    field(:source, :string, default: "manual")
    field(:active, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    version
    |> cast(attrs, [:project_id, :version, :raw_workflow_md, :yaml_config, :prompt_body, :source, :active])
    |> validate_required([:project_id, :version, :raw_workflow_md, :yaml_config, :prompt_body, :source])
    |> unique_constraint([:project_id, :version])
  end
end

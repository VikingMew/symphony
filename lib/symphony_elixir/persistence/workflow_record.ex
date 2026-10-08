defmodule SymphonyElixir.Persistence.WorkflowRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "workflows" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    field(:raw_workflow_md, :string)
    field(:yaml_config, :map, default: %{})
    field(:prompt_body, :string)
    field(:source, :string, default: "manual")
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:project_id, :raw_workflow_md, :yaml_config, :prompt_body, :source], empty_values: [])
    |> validate_required([:project_id, :raw_workflow_md, :yaml_config, :source])
    |> validate_prompt_body_present()
    |> unique_constraint(:project_id)
  end

  defp validate_prompt_body_present(changeset) do
    if is_nil(get_field(changeset, :prompt_body)),
      do: add_error(changeset, :prompt_body, "can't be nil"),
      else: changeset
  end
end

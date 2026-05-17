defmodule SymphonyElixir.Persistence.Project do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:linear_project_slug, :string)
    field(:repository_url, :string)
    field(:default_branch, :string, default: "main")
    field(:checkout_depth, :integer, default: 1)
    field(:source_strategy, :string, default: "clone")
    field(:worktree_base_path, :string)
    field(:worktree_root, :string)
    field(:worktree_fetch, :boolean, default: true)
    field(:worktree_cleanup, :boolean, default: true)
    field(:description, :string)
    field(:enabled, :boolean, default: true)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :slug,
      :linear_project_slug,
      :repository_url,
      :default_branch,
      :checkout_depth,
      :source_strategy,
      :worktree_base_path,
      :worktree_root,
      :worktree_fetch,
      :worktree_cleanup,
      :description,
      :enabled
    ])
    |> validate_required([:name, :slug, :default_branch])
    |> validate_number(:checkout_depth, greater_than: 0)
    |> validate_inclusion(:source_strategy, ["clone", "worktree"])
    |> unique_constraint(:slug)
  end
end

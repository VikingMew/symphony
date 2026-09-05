defmodule SymphonyElixir.Persistence.ReviewJob do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "review_jobs" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    belongs_to(:issue, SymphonyElixir.Persistence.IssueRecord)
    belongs_to(:run, SymphonyElixir.Persistence.RunRecord)
    field(:tracker_issue_id, :string)
    field(:issue_identifier, :string)
    field(:pr_url, :string)
    field(:repository, :string)
    field(:base_ref, :string)
    field(:head_ref, :string)
    field(:head_oid, :string)
    field(:status, :string, default: "intent")
    field(:result, :map)
    field(:delivery, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :project_id,
      :issue_id,
      :run_id,
      :tracker_issue_id,
      :issue_identifier,
      :pr_url,
      :repository,
      :base_ref,
      :head_ref,
      :head_oid,
      :status,
      :result,
      :delivery,
      :started_at,
      :finished_at
    ])
    |> validate_required([
      :project_id,
      :issue_id,
      :tracker_issue_id,
      :issue_identifier,
      :pr_url,
      :repository,
      :base_ref,
      :head_ref,
      :head_oid,
      :status
    ])
    |> validate_inclusion(:status, ~w(intent queued running completed failed superseded))
    |> unique_constraint([:project_id, :issue_id, :pr_url, :head_oid])
  end
end

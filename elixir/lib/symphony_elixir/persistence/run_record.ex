defmodule SymphonyElixir.Persistence.RunRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "runs" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
    belongs_to(:workflow_version, SymphonyElixir.Persistence.WorkflowVersion)
    belongs_to(:issue, SymphonyElixir.Persistence.IssueRecord)
    field(:kind, :string, default: "issue")
    field(:profile, :string)
    field(:label, :string)
    field(:issue_identifier, :string)
    field(:workspace_path, :string)
    field(:status, :string)
    field(:execution_mode, :string, default: "centralized")
    field(:attempt, :integer, default: 0)
    field(:failure_reason, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :project_id,
      :workflow_version_id,
      :issue_id,
      :kind,
      :profile,
      :label,
      :issue_identifier,
      :workspace_path,
      :status,
      :execution_mode,
      :attempt,
      :failure_reason,
      :started_at,
      :finished_at
    ])
    |> validate_required([:kind, :status])
    |> validate_inclusion(:kind, ["issue", "nap", "day_dreaming"])
    |> validate_issue_identifier_for_issue_run()
    |> validate_inclusion(:execution_mode, ["centralized", "worker"])
  end

  defp validate_issue_identifier_for_issue_run(changeset) do
    case get_field(changeset, :kind) do
      "issue" -> validate_required(changeset, [:issue_identifier])
      _ -> changeset
    end
  end
end

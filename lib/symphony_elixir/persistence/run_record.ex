defmodule SymphonyElixir.Persistence.RunRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.RunFailure

  @failure_classifications RunFailure.classifications()

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "runs" do
    belongs_to(:project, SymphonyElixir.Persistence.Project)
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
    field(:failure_evidence, :map)
    field(:execution_summary, :map)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :project_id,
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
      :failure_evidence,
      :execution_summary,
      :started_at,
      :finished_at
    ])
    |> validate_required([:kind, :status])
    |> validate_inclusion(:kind, ["issue", "review", "nap", "day_dreaming"])
    |> validate_inclusion(:status, ["running", "completed", "failed", "blocked", "cancelled", "stopped"])
    |> validate_issue_identifier_for_issue_run()
    |> validate_inclusion(:execution_mode, ["centralized", "worker"])
    |> validate_terminal_failure()
  end

  defp validate_issue_identifier_for_issue_run(changeset) do
    case get_field(changeset, :kind) do
      kind when kind in ["issue", "review"] -> validate_required(changeset, [:issue_identifier])
      _ -> changeset
    end
  end

  defp validate_terminal_failure(changeset) do
    status = get_field(changeset, :status)
    reason = get_field(changeset, :failure_reason)
    evidence = get_field(changeset, :failure_evidence)

    case status do
      status when status in ["running", "completed"] ->
        changeset
        |> require_nil(:failure_reason, reason, status)
        |> require_nil(:failure_evidence, evidence, status)

      status when status in ["failed", "blocked", "cancelled", "stopped"] ->
        changeset
        |> validate_failure_reason(reason)
        |> validate_failure_evidence(evidence)

      _ ->
        changeset
    end
  end

  defp require_nil(changeset, _field, nil, _status), do: changeset

  defp require_nil(changeset, field, _value, status),
    do: add_error(changeset, field, "must be empty when status is #{status}")

  defp validate_failure_reason(changeset, reason) when reason in @failure_classifications, do: changeset

  defp validate_failure_reason(changeset, _reason),
    do: add_error(changeset, :failure_reason, "must be a current run failure classification")

  defp validate_failure_evidence(changeset, evidence) when is_map(evidence) and map_size(evidence) > 0,
    do: changeset

  defp validate_failure_evidence(changeset, _evidence),
    do: add_error(changeset, :failure_evidence, "must be a non-empty object")
end

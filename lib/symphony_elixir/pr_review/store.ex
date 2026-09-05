defmodule SymphonyElixir.PRReview.Store do
  @moduledoc "Durable, idempotent storage for post-handoff review jobs."

  import Ecto.Query

  alias SymphonyElixir.Persistence.{ReviewJob, RunRecord}
  alias SymphonyElixir.Repo

  @active_statuses ~w(intent queued running)

  @spec put_intent(map()) :: {:ok, ReviewJob.t()} | {:error, term()}
  def put_intent(attrs) do
    %ReviewJob{}
    |> ReviewJob.changeset(Map.put(attrs, :status, "intent"))
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:project_id, :issue_id, :pr_url, :head_oid],
      returning: true
    )
    |> case do
      {:ok, %{id: nil}} ->
        {:ok,
         Repo.get_by!(ReviewJob,
           project_id: attrs.project_id,
           issue_id: attrs.issue_id,
           pr_url: attrs.pr_url,
           head_oid: attrs.head_oid
         )}

      result ->
        result
    end
  end

  @spec arm(ReviewJob.t()) :: {:ok, ReviewJob.t()} | {:error, Ecto.Changeset.t()}
  def arm(%ReviewJob{status: "intent"} = job) do
    Repo.transaction(fn ->
      {:ok, run} =
        %RunRecord{}
        |> RunRecord.changeset(%{
          project_id: job.project_id,
          issue_id: job.issue_id,
          kind: "review",
          profile: "review",
          label: "PR review #{job.head_oid}",
          issue_identifier: job.issue_identifier,
          status: "queued",
          started_at: DateTime.utc_now(),
          execution_summary: %{"pr_url" => job.pr_url, "head_oid" => job.head_oid}
        })
        |> Repo.insert()

      {:ok, armed} = __MODULE__.update(job, %{status: "queued", run_id: run.id})
      armed
    end)
  end

  def arm(%ReviewJob{} = job), do: {:ok, job}

  @spec queued(pos_integer()) :: [ReviewJob.t()]
  def queued(limit) when is_integer(limit) and limit > 0 do
    Repo.all(
      from(j in ReviewJob,
        where: j.status == "queued",
        order_by: [asc: j.inserted_at],
        limit: ^limit
      )
    )
  end

  @spec intents(pos_integer()) :: [ReviewJob.t()]
  def intents(limit) when is_integer(limit) and limit > 0 do
    Repo.all(
      from(j in ReviewJob,
        where: j.status == "intent",
        order_by: [asc: j.inserted_at],
        limit: ^limit
      )
    )
  end

  @spec claim(String.t()) :: {:ok, ReviewJob.t()} | :stale
  def claim(id) when is_binary(id) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(j in ReviewJob, where: j.id == ^id and j.status == "queued"),
        set: [status: "running", started_at: now, updated_at: now]
      )

    if count == 1, do: {:ok, Repo.get!(ReviewJob, id)}, else: :stale
  end

  @spec recover_running() :: non_neg_integer()
  def recover_running do
    {count, _} =
      Repo.update_all(
        from(j in ReviewJob, where: j.status == "running"),
        set: [status: "queued", started_at: nil, updated_at: DateTime.utc_now()]
      )

    count
  end

  @spec update(ReviewJob.t(), map()) :: {:ok, ReviewJob.t()} | {:error, Ecto.Changeset.t()}
  def update(%ReviewJob{} = job, attrs),
    do: job |> ReviewJob.changeset(attrs) |> Repo.update()

  @spec active_for_issue?(String.t()) :: boolean()
  def active_for_issue?(issue_id) when is_binary(issue_id) do
    Repo.exists?(from(j in ReviewJob, where: j.issue_id == ^issue_id and j.status in ^@active_statuses))
  end
end

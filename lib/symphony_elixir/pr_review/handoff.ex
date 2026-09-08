defmodule SymphonyElixir.PRReview.Handoff do
  @moduledoc "Records the recoverable handoff-to-review boundary."

  alias SymphonyElixir.{PersistenceProvider, PRReview}
  alias SymphonyElixir.PRReview.Queue

  @spec prepare(map(), map(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def prepare(issue, pull_request, project_id, run_id) do
    persistence = PersistenceProvider.module()

    with %{id: persisted_issue_id} <- persistence.get_issue(project_id, issue.identifier),
         {:ok, job} <-
           persistence.put_review_intent(%{
             project_id: project_id,
             issue_id: persisted_issue_id,
             run_id: run_id,
             tracker_issue_id: issue.id,
             issue_identifier: issue.identifier,
             pr_url: pull_request.url,
             repository: pull_request.repository,
             base_ref: pull_request.base,
             head_ref: pull_request.head,
             head_oid: pull_request.head_oid
           }) do
      {:ok, %{job: job, identity: PRReview.identity(project_id <> ":" <> issue.identifier, pull_request.url, pull_request.head_oid)}}
    else
      nil -> {:error, :issue_not_persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec arm(map()) :: :ok | {:error, term()}
  def arm(%{job: job}) do
    case PersistenceProvider.module().arm_review_job(job) do
      {:ok, _job} ->
        Queue.wake()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule SymphonyElixir.PRReview.Delivery do
  @moduledoc "Idempotently delivers one review result to Linear."

  alias SymphonyElixir.{BlockingDecision, PersistenceProvider, PRReview, Tracker}
  alias SymphonyElixir.PRReview.Store

  @spec deliver(map()) :: {:ok, map()} | {:error, term()}
  def deliver(job) do
    case job.result["outcome"] || job.result[:outcome] do
      outcome when outcome in ["approve", :approve] -> deliver_approve(job)
      outcome when outcome in ["findings", :findings] -> deliver_findings(job)
    end
  end

  defp deliver_approve(job) do
    case deliver_comment(job) do
      {:ok, job} -> Store.update(job, %{status: "completed", finished_at: DateTime.utc_now()})
      error -> error
    end
  end

  defp deliver_findings(job) do
    persistence = PersistenceProvider.module()
    issue = persistence.get_issue(job.project_id, job.issue_identifier)

    case issue.blocking_decision do
      %{} = existing ->
        case deliver_comment(job) do
          {:ok, job} ->
            delivery = Map.put(job.delivery, "blocking_conflict", existing)
            Store.update(job, %{status: "completed", delivery: delivery, finished_at: DateTime.utc_now()})

          error ->
            error
        end

      nil ->
        decision = decision(job, issue.state)

        with {:ok, _issue} <- persistence.update_issue(issue, %{blocking_decision: decision}),
             {:ok, job} <- Store.update(job, %{delivery: Map.put(job.delivery, "decision", "completed")}),
             {:ok, job} <- deliver_comment(job),
             {:ok, job} <- complete_decision_comment(job),
             {:ok, job} <- deliver_transition(job) do
          Store.update(job, %{status: "completed", finished_at: DateTime.utc_now()})
        end
    end
  end

  defp deliver_comment(%{delivery: %{"comment" => "completed"}} = job), do: {:ok, job}

  defp deliver_comment(job) do
    case Tracker.create_comment(job.tracker_issue_id, PRReview.comment(normalized_result(job))) do
      :ok -> Store.update(job, %{delivery: Map.put(job.delivery, "comment", "completed")})
      error -> error
    end
  end

  defp deliver_transition(%{delivery: %{"transition" => "completed"}} = job), do: {:ok, job}

  defp deliver_transition(job) do
    with :ok <- Tracker.update_issue_state(job.tracker_issue_id, "Blocked"),
         {:ok, job} <- Store.update(job, %{delivery: Map.put(job.delivery, "transition", "completed")}),
         issue <- PersistenceProvider.module().get_issue(job.project_id, job.issue_identifier),
         decision = Map.put(issue.blocking_decision, "transition_status", "completed"),
         {:ok, _issue} <-
           PersistenceProvider.module().update_issue(issue, %{
             state: "Blocked",
             blocking_decision: decision
           }) do
      {:ok, job}
    end
  end

  defp complete_decision_comment(job) do
    persistence = PersistenceProvider.module()
    issue = persistence.get_issue(job.project_id, job.issue_identifier)
    decision = Map.put(issue.blocking_decision, "comment_status", "completed")

    case persistence.update_issue(issue, %{blocking_decision: decision}) do
      {:ok, _issue} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalized_result(job) do
    {:ok, result} = PRReview.normalize(job.result)
    result
  end

  @doc false
  @spec decision(map(), String.t()) :: map()
  def decision(job, origin_state) do
    BlockingDecision.new(
      :pr_review,
      PRReview.comment(normalized_result(job)),
      job.run_id,
      origin_state,
      %{"pr_url" => job.pr_url},
      %{
        "review_job_id" => job.id,
        "review_head_oid" => job.head_oid
      }
    )
  end
end

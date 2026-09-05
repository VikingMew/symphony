defmodule SymphonyElixir.PRReview.Runner do
  @moduledoc "Runs one immutable pull-request review in a read-only Codex session."

  alias SymphonyElixir.{Codex.AppServer, GitHub.PullRequest, Linear.Issue, Tracker}

  @ready "Ready to Merge"

  @spec run(map(), keyword()) :: {:ok, map()} | {:superseded, term()} | {:error, term()}
  def run(job, opts \\ []) do
    context_loader = Keyword.get(opts, :context_loader, &PullRequest.review_context/2)
    state_fetcher = Keyword.get(opts, :state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    issue_context_loader = Keyword.get(opts, :issue_context_loader, &Tracker.fetch_review_context/1)
    app_server = Keyword.get(opts, :app_server, &AppServer.run/4)

    with {:ok, [%Issue{state: @ready} = issue]} <- state_fetcher.([job.tracker_issue_id]),
         {:ok, pr_context} <- context_loader.(job, Keyword.get(opts, :github_opts, [])),
         {:ok, issue_context} <- issue_context_loader.(job.tracker_issue_id),
         true <- pr_context["head_oid"] == job.head_oid,
         true <- get_in(pr_context, ["pull_request", "state"]) == "OPEN",
         workspace <- review_workspace(job, opts),
         :ok <- File.mkdir_p(workspace),
         context <- Map.put(pr_context, "issue", issue_context),
         {:ok, session} <-
           app_server.(workspace, prompt(job), issue,
             profile: "review",
             thread_sandbox: "read-only",
             turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => false},
             dynamic_tool_opts: [
               review_context: context,
               review_head_oid: job.head_oid
             ],
             on_message: &record_update(job, &1),
             run_id: job.run_id
           ),
         result when is_map(result) <- session.review_result do
      {:ok, result}
    else
      {:ok, [%Issue{}]} -> {:superseded, :issue_not_ready_to_merge}
      {:ok, []} -> {:superseded, :issue_missing}
      false -> {:superseded, :pull_request_head_or_state_changed}
      nil -> {:error, :review_result_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_update(job, message) do
    SymphonyElixir.PersistenceEventWriter.record(
      %{
        project_id: job.project_id,
        run_id: job.run_id,
        issue_identifier: job.issue_identifier,
        event_type: "codex.update",
        payload: Map.put(message, :profile, "review")
      },
      %{issue_id: job.tracker_issue_id, issue_identifier: job.issue_identifier, run_id: job.run_id}
    )
  end

  defp review_workspace(job, opts) do
    root =
      case Keyword.fetch(opts, :workspace_root) do
        {:ok, configured} -> configured
        :error -> SymphonyElixir.Config.settings!().workspace.root
      end

    Path.join([Path.expand(root), ".reviews", job.id])
  end

  defp prompt(job) do
    """
    Review pull request #{job.pr_url} at immutable head #{job.head_oid}.
    First call review_context_read. Compare the issue acceptance criteria, recent context,
    PR body/test plan, and diff. Check missing evidence and scope drift. Submit exactly one
    conclusion with submit_review. Approve only when the supplied evidence is sufficient;
    otherwise return actionable findings. Do not modify code, git, GitHub, or Linear.
    """
  end
end

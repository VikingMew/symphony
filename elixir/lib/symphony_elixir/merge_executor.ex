defmodule SymphonyElixir.MergeExecutor do
  @moduledoc """
  Backend-owned merge workflow for Linear `branchName`.
  """

  require Logger
  alias SymphonyElixir.{BranchName, Config, Git, Linear.Issue, PersistenceProvider, Tracker}

  @merge_profile "merge"

  @spec run(Path.t(), Issue.t(), keyword()) :: :ok | {:error, term()}
  def run(workspace, %Issue{} = issue, opts \\ []) when is_binary(workspace) do
    profile = Config.workflow_profile(@merge_profile)
    merge_policy = Map.get(profile, "merge", %{})
    settings = Config.settings!()
    branch = issue.branch_name
    remote = Map.get(merge_policy, "remote", "origin")
    base_branch = Map.get(merge_policy, "base_branch", settings.project.default_branch)
    push? = Map.get(merge_policy, "push", false) == true
    timeout_ms = Map.get(merge_policy, "timeout_ms", settings.hooks.timeout_ms)
    success_state = Map.get(merge_policy, "success_state") || first_merge_success_state(profile)
    start_state = Map.get(merge_policy, "start_state", "Merging")
    git_opts = Keyword.get(opts, :git_opts, [])

    with {:ok, branch} <- BranchName.validate(branch),
         :ok <- ensure_project_repository_configured(settings),
         :ok <- record_phase(issue, :merge_branch_validation, :completed, %{branch: branch}),
         :ok <- maybe_transition(issue, start_state, opts, :merge_started),
         {:ok, true} <- remote_branch_exists?(workspace, branch, remote, timeout_ms, git_opts),
         :ok <- record_phase(issue, :merge_remote_branch, :completed, %{branch: branch, remote: remote}),
         {:ok, output} <-
           merge_branch(workspace, branch,
             remote: remote,
             base_branch: base_branch,
             push: push?,
             timeout_ms: timeout_ms,
             git_opts: git_opts
           ),
         :ok <-
           record_phase(issue, :merge_backend, :completed, %{
             branch: branch,
             base_branch: base_branch,
             push: push?,
             output: output
           }),
         :ok <- maybe_transition(%{issue | state: start_state}, success_state, opts, :merge_completed) do
      :ok
    else
      {:ok, false} ->
        fail(issue, :merge_remote_branch, {:remote_branch_not_found, branch})

      {:error, reason} ->
        fail(issue, :merge_backend, reason)
    end
  end

  defp ensure_project_repository_configured(%{project: %{repository_url: url}}) when is_binary(url) and url != "", do: :ok
  defp ensure_project_repository_configured(_settings), do: {:error, :missing_project_repository_url}

  defp remote_branch_exists?(workspace, branch, remote, timeout_ms, git_opts) do
    checker = Keyword.get(git_opts, :remote_branch_checker)

    if is_function(checker, 3) do
      checker.(workspace, branch, remote)
    else
      Git.remote_branch_exists?(workspace, branch, Keyword.merge(git_opts, remote: remote, timeout_ms: timeout_ms))
    end
  end

  defp merge_branch(workspace, branch, opts) do
    git_opts = Keyword.fetch!(opts, :git_opts)

    Git.merge_branch(
      workspace,
      branch,
      Keyword.merge(git_opts,
        remote: Keyword.fetch!(opts, :remote),
        base_branch: Keyword.fetch!(opts, :base_branch),
        push: Keyword.fetch!(opts, :push),
        timeout_ms: Keyword.fetch!(opts, :timeout_ms)
      )
    )
  end

  defp maybe_transition(_issue, nil, _opts, _reason), do: :ok

  defp maybe_transition(issue, target_state, opts, reason) do
    case transition_need(issue, target_state) do
      :ok ->
        :ok

      :continue ->
        if transition_allowed?(issue.state, target_state) do
          run_transition(issue, target_state, opts, reason)
        else
          {:error, {:transition_not_allowed, issue.state, target_state, @merge_profile}}
        end
    end
  end

  defp run_transition(issue, target_state, opts, notify_reason) do
    opts
    |> Keyword.get(:merge_state_transitioner, &default_state_transitioner/2)
    |> then(& &1.(issue, target_state))
    |> handle_transition_result(issue, target_state, opts, notify_reason)
  end

  defp handle_transition_result(:ok, issue, target_state, opts, reason) do
    notify_backend_transition(issue, target_state, opts, reason)
    :ok
  end

  defp handle_transition_result({:ok, %Issue{}}, issue, target_state, opts, reason) do
    notify_backend_transition(issue, target_state, opts, reason)
    :ok
  end

  defp handle_transition_result({:error, reason}, _issue, target_state, _opts, _notify_reason) do
    {:error, {:merge_state_transition_failed, target_state, reason}}
  end

  defp handle_transition_result(other, _issue, target_state, _opts, _notify_reason) do
    {:error, {:merge_state_transition_failed, target_state, {:unexpected_transition_result, other}}}
  end

  defp transition_need(%Issue{state: state}, target_state)
       when is_binary(state) and is_binary(target_state) do
    if normalize_state(state) == normalize_state(target_state), do: :ok, else: :continue
  end

  defp transition_need(_issue, _target_state), do: :continue

  defp transition_allowed?(from_state, to_state) do
    Config.settings!().workflow
    |> Map.get("allowed_transitions", [])
    |> Enum.any?(fn
      %{} = transition ->
        transition_profile = Map.get(transition, "profile")
        actor = Map.get(transition, "actor")

        normalize_state(Map.get(transition, "from", "")) == normalize_state(from_state) &&
          normalize_state(Map.get(transition, "to", "")) == normalize_state(to_state) &&
          transition_profile in [nil, @merge_profile] &&
          actor in [nil, "codex", "symphony"]

      _ ->
        false
    end)
  end

  defp default_state_transitioner(%Issue{id: issue_id}, target_state) when is_binary(issue_id) and issue_id != "" do
    Tracker.update_issue_state(issue_id, target_state)
  end

  defp default_state_transitioner(%Issue{} = issue, target_state), do: {:error, {:missing_issue_id, issue.identifier, target_state}}

  defp notify_backend_transition(%Issue{id: issue_id, state: from_state}, to_state, opts, reason)
       when is_binary(issue_id) do
    case Keyword.get(opts, :codex_update_recipient) do
      recipient when is_pid(recipient) ->
        send(
          recipient,
          {:linear_state_transition, issue_id,
           %{
             from_state: from_state,
             to_state: to_state,
             rollback_to_state: from_state,
             source: :symphony_backend,
             reason: reason,
             occurred_at: DateTime.utc_now()
           }}
        )

      _ ->
        :ok
    end
  end

  defp notify_backend_transition(_issue, _to_state, _opts, _reason), do: :ok

  defp first_merge_success_state(profile) do
    profile
    |> get_in(["allowed_updates", "target_states"])
    |> case do
      states when is_list(states) -> Enum.find(states, &(&1 not in ["Merging", "Ready to Merge"]))
      _ -> nil
    end
  end

  defp fail(issue, phase, reason) do
    record_phase(issue, phase, :failed, %{reason: inspect(reason)})
    {:error, reason}
  end

  defp record_phase(%Issue{} = issue, phase, status, payload) do
    Logger.info("Run phase phase=#{phase} status=#{status} issue_id=#{issue.id} issue_identifier=#{issue.identifier}")

    PersistenceProvider.module().record_event(%{
      issue_identifier: issue.identifier,
      event_type: "run.phase",
      payload:
        Map.merge(
          %{
            phase: to_string(phase),
            status: to_string(status),
            issue_id: issue.id,
            issue_identifier: issue.identifier
          },
          payload
        )
    })

    :ok
  rescue
    _ -> :ok
  end

  defp normalize_state(state), do: state |> to_string() |> String.trim() |> String.downcase()
end

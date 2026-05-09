defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.{
    BranchName,
    Codex.AppServer,
    Config,
    Git,
    Linear.Issue,
    MergeExecutor,
    PersistenceProvider,
    PromptBuilder,
    Tracker,
    Workspace
  }

  @implementation_profile "implementation"
  @merge_profile "merge"
  @implementation_start_state "Ready"
  @implementation_started_state "In Progress"

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    emit_phase(issue, :workspace_preparing, :started, worker_host, opts)

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        emit_phase(issue, :workspace_preparing, :completed, worker_host, opts, %{workspace: workspace})
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_profile(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        emit_phase(issue, :workspace_preparing, :failed, worker_host, opts, %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_profile(workspace, issue, codex_update_recipient, opts, worker_host) do
    case Config.workflow_profile_for_state(issue.state) do
      @merge_profile ->
        run_merge(workspace, issue, codex_update_recipient, opts, worker_host)

      @implementation_profile ->
        with :ok <- prepare_implementation_branch(workspace, issue, opts) do
          run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
        end

      _profile ->
        run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp run_merge(workspace, issue, codex_update_recipient, opts, worker_host) do
    emit_phase(issue, :merge_backend, :started, worker_host, opts, %{workspace: workspace})

    merge_opts =
      opts
      |> Keyword.put_new(:codex_update_recipient, codex_update_recipient)
      |> Keyword.put_new(:git_opts, Keyword.get(opts, :git_opts, []))

    merge_executor = Keyword.get(opts, :merge_executor, &MergeExecutor.run/3)

    case merge_executor.(workspace, issue, merge_opts) do
      :ok ->
        emit_phase(issue, :merge_backend, :completed, worker_host, opts, %{workspace: workspace})
        :ok

      {:error, reason} ->
        emit_phase(issue, :merge_backend, :failed, worker_host, opts, %{workspace: workspace, reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp prepare_implementation_branch(workspace, %Issue{} = issue, opts) do
    if project_repository_configured?() do
      with {:ok, branch} <- BranchName.validate(issue.branch_name),
           :ok <- emit_branch_event(issue, :implementation_branch_validation, :completed, %{branch: branch}),
           {:ok, _output} <- checkout_implementation_branch(workspace, branch, opts) do
        emit_branch_event(issue, :implementation_branch_checkout, :completed, %{branch: branch})
      else
        {:error, reason} ->
          emit_branch_event(issue, :implementation_branch_checkout, :failed, %{reason: inspect(reason)})
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp project_repository_configured? do
    case Config.settings!().project.repository_url do
      repository_url when is_binary(repository_url) and repository_url != "" -> true
      _ -> false
    end
  end

  defp checkout_implementation_branch(workspace, branch, opts) do
    git_opts = Keyword.get(opts, :git_opts, [])
    checkout = Keyword.get(opts, :implementation_branch_checkout, &Git.checkout_work_branch/3)
    checkout.(workspace, branch, git_opts)
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    opts = Keyword.put_new(opts, :codex_update_recipient, codex_update_recipient)

    emit_phase(issue, :codex_starting, :started, worker_host, opts, %{workspace: workspace})

    case AppServer.start_session(workspace, worker_host: worker_host) do
      {:ok, session} ->
        emit_phase(issue, :codex_starting, :completed, worker_host, opts, %{workspace: workspace})
        emit_phase(issue, :codex_running, :started, worker_host, opts, %{workspace: workspace})

        result =
          try do
            with {:ok, started_issue} <- maybe_mark_implementation_started(issue, opts) do
              do_run_codex_turns(
                session,
                workspace,
                started_issue,
                codex_update_recipient,
                opts,
                issue_state_fetcher,
                1,
                max_turns
              )
            end
          after
            AppServer.stop_session(session)
          end

        case result do
          :ok ->
            emit_phase(issue, :codex_running, :completed, worker_host, opts, %{workspace: workspace})

          {:error, reason} ->
            emit_phase(issue, :codex_running, :failed, worker_host, opts, %{
              workspace: workspace,
              reason: inspect(reason)
            })
        end

        result

      {:error, reason} ->
        emit_phase(issue, :codex_starting, :failed, worker_host, opts, %{workspace: workspace, reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp maybe_mark_implementation_started(%Issue{} = issue, opts) do
    profile = Config.workflow_profile_for_state(issue.state)

    if implementation_start_transition_required?(issue, profile) do
      transition_implementation_start(issue, profile, opts)
    else
      {:ok, issue}
    end
  end

  defp implementation_start_transition_required?(%Issue{state: state}, @implementation_profile) do
    normalize_issue_state(state) == normalize_issue_state(@implementation_start_state)
  end

  defp implementation_start_transition_required?(_issue, _profile), do: false

  defp transition_implementation_start(%Issue{id: issue_id} = issue, profile, opts)
       when is_binary(issue_id) and issue_id != "" do
    with :ok <- validate_implementation_start_transition(issue.state, @implementation_started_state, profile),
         :ok <- call_implementation_start_transitioner(issue, @implementation_started_state, opts) do
      Logger.info("Moved issue to implementation start state for #{issue_context(issue)} state=#{@implementation_started_state}")
      notify_backend_transition(issue, @implementation_start_state, @implementation_started_state, opts)
      {:ok, %{issue | state: @implementation_started_state}}
    else
      {:error, reason} -> {:error, {:implementation_start_transition_failed, reason}}
    end
  end

  defp transition_implementation_start(%Issue{} = issue, _profile, _opts) do
    {:error, {:implementation_start_transition_failed, {:missing_issue_id, issue.identifier}}}
  end

  defp validate_implementation_start_transition(from_state, to_state, profile) do
    if workflow_transition_allowed?(from_state, to_state, profile) do
      :ok
    else
      {:error, {:transition_not_allowed, from_state, to_state, profile}}
    end
  end

  defp workflow_transition_allowed?(from_state, to_state, profile) do
    Config.settings!().workflow
    |> Map.get("allowed_transitions", [])
    |> Enum.any?(&matching_transition?(&1, from_state, to_state, profile))
  end

  defp matching_transition?(%{} = transition, from_state, to_state, profile) do
    transition_profile = Map.get(transition, "profile")
    actor = Map.get(transition, "actor")

    normalize_issue_state(Map.get(transition, "from", "")) == normalize_issue_state(from_state) &&
      normalize_issue_state(Map.get(transition, "to", "")) == normalize_issue_state(to_state) &&
      transition_profile in [nil, profile] &&
      actor in [nil, "codex", "symphony"]
  end

  defp matching_transition?(_transition, _from_state, _to_state, _profile), do: false

  defp call_implementation_start_transitioner(issue, target_state, opts) do
    transitioner = Keyword.get(opts, :implementation_start_transitioner, &default_implementation_start_transitioner/2)

    case transitioner.(issue, target_state) do
      :ok -> :ok
      {:ok, %Issue{}} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_transition_result, other}}
    end
  end

  defp default_implementation_start_transitioner(%Issue{id: issue_id}, target_state) do
    Tracker.update_issue_state(issue_id, target_state)
  end

  defp notify_backend_transition(%Issue{id: issue_id}, from_state, to_state, opts)
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
             reason: :implementation_started,
             occurred_at: DateTime.utc_now()
           }}
        )

      _ ->
        :ok
    end
  end

  defp notify_backend_transition(_issue, _from_state, _to_state, _opts), do: :ok

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             workspace: workspace
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    profile = Config.workflow_profile_for_state(issue.state)

    prompt_opts =
      opts
      |> Keyword.put_new(:profile, profile)
      |> Keyword.put_new(:profile_policy, Config.workflow_profile(profile))
      |> Keyword.put_new(:allowed_updates, Config.workflow_allowed_updates(profile))

    PromptBuilder.build_prompt(issue, prompt_opts)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp emit_phase(issue, phase, status, worker_host, opts, extra_payload \\ %{}) do
    payload =
      %{
        phase: to_string(phase),
        status: to_string(status),
        worker_host: worker_host_for_log(worker_host),
        attempt: Keyword.get(opts, :attempt)
      }
      |> Map.merge(issue_phase_payload(issue))
      |> Map.merge(extra_payload)

    Logger.info(
      "Run phase phase=#{payload.phase} status=#{payload.status} issue_id=#{Map.get(payload, :issue_id)} issue_identifier=#{Map.get(payload, :issue_identifier)} worker_host=#{payload.worker_host} attempt=#{inspect(payload.attempt)}"
    )

    PersistenceProvider.module().record_event(%{
      issue_identifier: Map.get(payload, :issue_identifier),
      event_type: "run.phase",
      payload: payload
    })

    :ok
  rescue
    _ -> :ok
  end

  defp issue_phase_payload(%Issue{id: issue_id, identifier: identifier}) do
    %{issue_id: issue_id, issue_identifier: identifier}
  end

  defp issue_phase_payload(_issue), do: %{}

  defp emit_branch_event(%Issue{} = issue, phase, status, payload) do
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
end

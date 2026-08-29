defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.{
    AgentRunner.Policy,
    BranchName,
    Codex.AppServer,
    Codex.RateLimitGate,
    Config,
    Git,
    Linear.Issue,
    PersistenceEventWriter,
    PromptBuilder,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.GitHub.PullRequest

  @implementation_profile "implementation"
  @implementation_start_state "Ready"
  @implementation_started_state "In Progress"

  @type worker_host :: String.t() | nil
  @type operator_kind :: :nap | :day_dreaming
  @type operator_task_identity :: %{
          identifier: String.t(),
          label: String.t(),
          description: String.t()
        }

  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      Policy.selected_worker_host(
        Keyword.get(opts, :worker_host),
        Config.settings!().worker.ssh_hosts
      )

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{Policy.failure_summary(reason)}")

        {:error, reason}
    end
  end

  @spec run_operator(atom(), String.t(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run_operator(kind, run_id, codex_update_recipient \\ nil, opts \\ [])
      when kind in [:nap, :day_dreaming] and is_binary(run_id) do
    profile = to_string(kind)
    identity = operator_task_identity(kind, run_id)

    issue = %Issue{
      id: run_id,
      identifier: identity.identifier,
      title: identity.label,
      description: identity.description,
      state: identity.label,
      labels: ["operator", profile],
      assigned_to_worker: false
    }

    worker_host =
      Policy.selected_worker_host(
        Keyword.get(opts, :worker_host),
        Config.settings!().worker.ssh_hosts
      )

    opts = Keyword.put(opts, :operator_profile, profile)

    Logger.info("Starting operator run kind=#{profile} run_id=#{run_id} worker_host=#{worker_host_for_log(worker_host)}")

    case run_operator_on_worker_host(issue, profile, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Operator run failed kind=#{profile} run_id=#{run_id}: #{Policy.failure_summary(reason)}")

        {:error, reason}
    end
  end

  @spec operator_task_identity(operator_kind(), term()) :: operator_task_identity()
  def operator_task_identity(kind, run_id) when kind in [:nap, :day_dreaming] do
    %{
      identifier: operator_identifier(kind, run_id),
      label: operator_title(kind),
      description: operator_description(kind)
    }
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    with_workspace(issue, codex_update_recipient, opts, worker_host, fn workspace ->
      run_profile(workspace, issue, codex_update_recipient, opts, worker_host)
    end)
  end

  defp run_operator_on_worker_host(issue, profile, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting operator worker attempt for #{issue_context(issue)} profile=#{profile} worker_host=#{worker_host_for_log(worker_host)}")

    with_workspace(issue, codex_update_recipient, opts, worker_host, fn workspace ->
      run_operator_codex_turn(
        workspace,
        issue,
        profile,
        codex_update_recipient,
        opts,
        worker_host
      )
    end)
  end

  defp with_workspace(issue, codex_update_recipient, opts, worker_host, run) do
    emit_phase(issue, :workspace_preparing, :started, worker_host, opts)

    workspace_opts = [
      progress_recipient: codex_update_recipient,
      project_id: Keyword.get(opts, :project_id)
    ]

    workspace_creator = Keyword.get(opts, :workspace_creator, &Workspace.create_for_issue/3)

    case workspace_creator.(issue, worker_host, workspace_opts) do
      {:ok, workspace} ->
        emit_phase(issue, :workspace_preparing, :completed, worker_host, opts, %{
          workspace: workspace
        })

        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host, workspace_opts) do
            run.(workspace)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host, workspace_opts)
        end

      {:error, reason} ->
        emit_phase(issue, :workspace_preparing, :failed, worker_host, opts, %{
          reason: inspect(reason)
        })

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
      @implementation_profile ->
        with :ok <- prepare_implementation_branch(workspace, issue, opts) do
          run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
        end

      profile when is_binary(profile) and profile != "" ->
        run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)

      _profile ->
        {:error, {:workflow_state_not_executable, issue.state}}
    end
  end

  defp prepare_implementation_branch(workspace, %Issue{} = issue, opts) do
    if project_repository_configured?() do
      with {:ok, branch} <- BranchName.validate(issue.branch_name),
           :ok <-
             emit_branch_event(issue, :implementation_branch_validation, :completed, %{
               branch: branch
             }),
           {:ok, _output} <- checkout_implementation_branch(workspace, branch, opts) do
        emit_branch_event(issue, :implementation_branch_checkout, :completed, %{branch: branch})
      else
        {:error, reason} ->
          emit_branch_event(issue, :implementation_branch_checkout, :failed, %{
            reason: inspect(reason)
          })

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

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    dynamic_tool_opts =
      opts
      |> Keyword.get(:dynamic_tool_opts, [])
      |> Keyword.put_new(:pull_request_proof_secret, :crypto.strong_rand_bytes(32))
      |> Keyword.put_new(
        :pull_request_creator,
        pull_request_creator(worker_host, opts)
      )
      |> Keyword.put_new(
        :task_update_observer,
        task_update_observer(codex_update_recipient, issue.id)
      )

    opts =
      opts
      |> Keyword.put_new(:codex_update_recipient, codex_update_recipient)
      |> Keyword.put(:dynamic_tool_opts, dynamic_tool_opts)

    with_codex_session(
      workspace,
      issue,
      opts,
      worker_host,
      fn -> {:ok, nil} end,
      fn session, nil ->
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
      end
    )
  end

  defp maybe_mark_implementation_started(%Issue{} = issue, opts) do
    profile = Config.workflow_profile_for_state(issue.state)

    if Policy.implementation_start_transition_required?(issue, profile) do
      transition_implementation_start(issue, profile, opts)
    else
      {:ok, issue}
    end
  end

  defp transition_implementation_start(%Issue{id: issue_id} = issue, profile, opts)
       when is_binary(issue_id) and issue_id != "" do
    with :ok <-
           validate_implementation_start_transition(
             issue.state,
             @implementation_started_state,
             profile
           ),
         :ok <- call_implementation_start_transitioner(issue, @implementation_started_state, opts) do
      Logger.info("Moved issue to implementation start state for #{issue_context(issue)} state=#{@implementation_started_state}")

      notify_backend_transition(
        issue,
        @implementation_start_state,
        @implementation_started_state,
        opts
      )

      {:ok, %{issue | state: @implementation_started_state}}
    else
      {:error, reason} -> {:error, {:implementation_start_transition_failed, reason}}
    end
  end

  defp transition_implementation_start(%Issue{} = issue, _profile, _opts) do
    {:error, {:implementation_start_transition_failed, {:missing_issue_id, issue.identifier}}}
  end

  defp validate_implementation_start_transition(from_state, to_state, profile) do
    transitions = Config.settings!().workflow |> Map.get("allowed_transitions", [])

    case Policy.validate_implementation_start_transition(transitions, from_state, profile) do
      :ok ->
        :ok

      {:error, {:transition_not_allowed, ^from_state, _expected_to_state, ^profile}} ->
        {:error, {:transition_not_allowed, from_state, to_state, profile}}
    end
  end

  defp call_implementation_start_transitioner(issue, target_state, opts) do
    transitioner =
      Keyword.get(
        opts,
        :implementation_start_transitioner,
        &default_implementation_start_transitioner/2
      )

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

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             workspace: workspace,
             run_id: Keyword.get(opts, :run_id),
             dynamic_tool_opts: Keyword.get(opts, :dynamic_tool_opts, [])
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case Policy.continue_with_issue?(issue, issue_state_fetcher, continuation_settings(issue)) do
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

        {:done, refreshed_issue, reason} ->
          Logger.info(
            "Stopping agent continuation for #{issue_context(refreshed_issue)} reason=#{reason} state=#{inspect(refreshed_issue.state)} profile=#{inspect(Config.workflow_profile_for_state(refreshed_issue.state))}"
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp pull_request_creator(worker_host, runner_opts) do
    fn issue, rendered, tool_opts ->
      event_opts = handoff_event_opts(runner_opts, tool_opts)
      emit_phase(issue, :implementation_handoff, :started, worker_host, event_opts)

      pull_request_ensurer =
        Keyword.get(runner_opts, :pull_request_ensurer, &PullRequest.ensure_open/4)

      github_opts = Keyword.get(runner_opts, :github_opts, [])

      case pull_request_ensurer.(
             issue,
             Config.settings!().project,
             rendered,
             github_opts
           ) do
        {:ok, pull_request} ->
          emit_phase(
            issue,
            :implementation_handoff,
            :completed,
            worker_host,
            event_opts,
            pull_request
          )

          {:ok, pull_request}

        {:error, reason} ->
          emit_phase(issue, :implementation_handoff, :failed, worker_host, event_opts, %{
            reason: inspect(reason)
          })

          {:error, {:implementation_handoff_failed, reason}}

        other ->
          reason = {:unexpected_pull_request_result, other}

          emit_phase(issue, :implementation_handoff, :failed, worker_host, event_opts, %{
            reason: inspect(reason)
          })

          {:error, {:implementation_handoff_failed, reason}}
      end
    end
  end

  defp task_update_observer(recipient, issue_id) when is_pid(recipient) do
    fn result, payload, _tool_opts ->
      send(recipient, {
        :linear_task_update_result,
        issue_id,
        result,
        Map.get(payload, "result"),
        Map.get(payload, "references", %{}),
        Map.get(payload, "target_state")
      })
    end
  end

  defp task_update_observer(_recipient, _issue_id), do: fn _result, _payload, _tool_opts -> :ok end

  defp handoff_event_opts(runner_opts, tool_opts) do
    runner_opts
    |> Keyword.put(:session_id, Keyword.get(tool_opts, :session_id))
    |> Keyword.put_new(:run_id, Keyword.get(tool_opts, :run_id))
  end

  defp run_operator_codex_turn(
         workspace,
         issue,
         profile,
         codex_update_recipient,
         opts,
         worker_host
       ) do
    opts = Keyword.put_new(opts, :codex_update_recipient, codex_update_recipient)

    with_codex_session(
      workspace,
      issue,
      opts,
      worker_host,
      fn -> operator_profile_policy(profile) end,
      fn app_session, profile_policy ->
        prompt =
          PromptBuilder.build_prompt(
            issue,
            opts
            |> Keyword.put(:profile, profile)
            |> Keyword.put(:profile_policy, profile_policy)
            |> Keyword.put(:allowed_updates, Config.workflow_allowed_updates(profile))
          )

        with {:ok, turn_session} <-
               AppServer.run_turn(
                 app_session,
                 prompt,
                 issue,
                 on_message: codex_message_handler(codex_update_recipient, issue),
                 workspace: workspace,
                 profile: profile,
                 operator_kind: profile,
                 run_id: Keyword.get(opts, :run_id)
               ) do
          Logger.info("Completed operator run for #{issue_context(issue)} profile=#{profile} session_id=#{turn_session[:session_id]} workspace=#{workspace}")

          :ok
        end
      end
    )
  end

  defp with_codex_session(workspace, issue, opts, worker_host, prepare, run) do
    emit_phase(issue, :codex_starting, :started, worker_host, opts, %{workspace: workspace})

    with :allow <- rate_limit_gate_allows_session_start(opts),
         {:ok, run_context} <- prepare.(),
         {:ok, app_session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      emit_phase(issue, :codex_starting, :completed, worker_host, opts, %{workspace: workspace})
      emit_phase(issue, :codex_running, :started, worker_host, opts, %{workspace: workspace})

      result =
        try do
          run.(app_session, run_context)
        after
          AppServer.stop_session(app_session)
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
    else
      {:block, details} ->
        emit_phase(issue, :codex_starting, :failed, worker_host, opts, %{
          workspace: workspace,
          reason: inspect({:rate_limit_gate_blocked, details})
        })

        {:error, {:codex_rate_limit_gate_blocked, details}}

      {:error, reason} ->
        emit_phase(issue, :codex_starting, :failed, worker_host, opts, %{
          workspace: workspace,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  defp operator_profile_policy(profile) do
    {:ok, Config.workflow_profile(profile)}
  end

  defp rate_limit_gate_allows_session_start(opts) do
    snapshot = Keyword.get(opts, :rate_limit_snapshot)
    settings = Keyword.get(opts, :rate_limit_settings) || Config.settings!()
    RateLimitGate.check(snapshot, settings)
  end

  defp continuation_settings(%Issue{state: state}) do
    config = Config.settings!()

    %{
      active_states: config.tracker.active_states,
      terminal_states: config.tracker.terminal_states,
      current_profile: Config.workflow_profile_for_state(state),
      profile_for_state: &Config.workflow_profile_for_state/1,
      executor_for_state: &Config.workflow_executor_for_state/1,
      human_review_state?: &Config.human_review_state?/1
    }
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

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp operator_identifier(kind, run_id) when is_binary(run_id) do
    suffix =
      run_id
      |> String.replace(~r/[^A-Za-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(-12, 12)

    kind
    |> to_string()
    |> String.replace("_", "-")
    |> String.upcase()
    |> Kernel.<>("-#{suffix}")
  end

  defp operator_identifier(kind, _run_id), do: to_string(kind)

  defp operator_title(:nap), do: "Nap"
  defp operator_title(:day_dreaming), do: "Day dreaming"

  defp operator_description(:nap),
    do: "Audit project context and create focused backlog issues without modifying the repository."

  defp operator_description(:day_dreaming),
    do: "Explore project direction and create focused product discovery backlog issues without modifying the repository."

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp emit_phase(issue, phase, status, worker_host, opts, extra_payload \\ %{}) do
    payload =
      %{
        phase: to_string(phase),
        status: to_string(status),
        worker_host: worker_host_for_log(worker_host),
        attempt: Keyword.get(opts, :attempt),
        session_id: Keyword.get(opts, :session_id)
      }
      |> Map.merge(issue_phase_payload(issue))
      |> Map.merge(extra_payload)

    Logger.info(
      "Run phase phase=#{payload.phase} status=#{payload.status} issue_id=#{Map.get(payload, :issue_id)} issue_identifier=#{Map.get(payload, :issue_identifier)} worker_host=#{payload.worker_host} attempt=#{inspect(payload.attempt)}"
    )

    record_telemetry_event(
      %{
        issue_identifier: Map.get(payload, :issue_identifier),
        run_id: Keyword.get(opts, :run_id),
        event_type: "run.phase",
        payload: payload
      },
      %{
        issue_id: Map.get(payload, :issue_id),
        issue_identifier: Map.get(payload, :issue_identifier),
        session_id: Keyword.get(opts, :session_id),
        run_id: Keyword.get(opts, :run_id)
      }
    )
  end

  defp issue_phase_payload(%Issue{id: issue_id, identifier: identifier}) do
    %{issue_id: issue_id, issue_identifier: identifier}
  end

  defp issue_phase_payload(_issue), do: %{}

  defp emit_branch_event(%Issue{} = issue, phase, status, payload) do
    record_telemetry_event(
      %{
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
      },
      %{issue_id: issue.id, issue_identifier: issue.identifier}
    )
  end

  # Phase events are best-effort telemetry: persistence failure is visible but
  # must not change the agent action being measured.
  defp record_telemetry_event(attrs, context) do
    case PersistenceEventWriter.record(attrs, context) do
      :ok ->
        :ok

      {_outcome, reason} ->
        Logger.warning(
          "Run phase persistence degraded action=continue_degraded event_type=#{Map.get(attrs, :event_type)} issue_id=#{inspect(Map.get(context, :issue_id))} issue_identifier=#{inspect(Map.get(context, :issue_identifier))} session_id=#{inspect(Map.get(context, :session_id))} run_id=#{inspect(Map.get(context, :run_id))} outcome=#{inspect({:degraded, reason}, limit: 20, printable_limit: 1_000)}"
        )

        :ok
    end
  end
end

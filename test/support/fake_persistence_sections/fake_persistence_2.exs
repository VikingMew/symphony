# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.FakePersistence.Sections.FakePersistence2 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      alias SymphonyElixir.Config.{LegacyWorkflowConvergence, ProjectAuthority, WorkflowScopes}
      alias SymphonyElixir.Persistence.Project

      def list_events(opts \\ []) do
        ensure_started()

        Agent.get(@name, fn state ->
          state.events
          |> filter_eq(:issue_identifier, Keyword.get(opts, :issue_identifier))
          |> filter_eq(:run_id, Keyword.get(opts, :run_id))
          |> filter_eq(:event_type, Keyword.get(opts, :event_type))
          |> filter_eq(:project_id, Keyword.get(opts, :project_id))
          |> sort_events(Keyword.get(opts, :order))
          |> Enum.take(Keyword.get(opts, :limit, length(state.events)))
        end)
      end

      def list_analytics_events do
        ensure_started()
        Agent.get(@name, & &1.events)
      end

      def get_event(id), do: Agent.get(@name, fn state -> Enum.find(state.events, &(&1.id == id)) end)

      def worker_event_transaction(fun), do: fun.()

      def record_event(attrs) when is_map(attrs) do
        ensure_started()

        event =
          attrs
          |> Map.put_new(:id, "event-#{System.unique_integer([:positive])}")
          |> Map.put_new(:occurred_at, DateTime.utc_now())

        Agent.update(@name, fn state ->
          state
          |> record_call({:record_event, event})
          |> update_in([:events], &[event | &1])
        end)

        {:ok, event}
      end

      def list_workers(_opts \\ []) do
        ensure_started()
        Agent.get(@name, & &1.workers)
      end

      def list_worker_sessions(_opts \\ []) do
        ensure_started()
        Agent.get(@name, & &1.worker_sessions)
      end

      def available_worker_slots(opts \\ []) do
        ensure_started()

        Agent.get_and_update(@name, fn state ->
          capacity =
            state.worker_sessions
            |> Enum.filter(&(Map.get(&1, :status) == "online"))
            |> Enum.sum_by(&Map.fetch!(&1, :total_slots))

          {capacity, record_call(state, {:available_worker_slots, opts})}
        end)
      end

      def active_worker_session(worker_id, session_id) do
        ensure_started()

        Agent.get(@name, fn state ->
          worker = Enum.find(state.workers, &(Map.get(&1, :id) == worker_id))
          session = Enum.find(state.worker_sessions, &(Map.get(&1, :id) == session_id))
          if worker && session && session.worker_id == worker_id && session.status == "online", do: {:ok, worker, session}, else: {:error, :worker_session_not_found}
        end)
      end

      def worker_session_identity(worker_id, session_id) do
        ensure_started()

        Agent.get_and_update(@name, fn state ->
          worker = Enum.find(state.workers, &(Map.get(&1, :id) == worker_id))
          session = Enum.find(state.worker_sessions, &(Map.get(&1, :id) == session_id))

          result =
            if worker && session && session.worker_id == worker_id,
              do: {:ok, worker, session},
              else: {:error, :worker_session_not_found}

          {result, record_call(state, {:worker_session_identity, worker_id, session_id})}
        end)
      end

      def fresh_worker_session(worker_id, session_id, opts \\ []) do
        now = Keyword.get(opts, :now, DateTime.utc_now())
        timeout = Keyword.get(opts, :heartbeat_timeout_seconds, worker_heartbeat_interval_seconds() * 3)
        cutoff = DateTime.add(now, -timeout, :second)

        Agent.get_and_update(@name, fn state ->
          worker = Enum.find(state.workers, &(Map.get(&1, :id) == worker_id))
          session = Enum.find(state.worker_sessions, &(Map.get(&1, :id) == session_id))

          result =
            case {worker, session} do
              {worker, %{worker_id: ^worker_id, status: "online"} = session} when not is_nil(worker) ->
                fresh_session_result(worker, session, cutoff)

              {worker, %{worker_id: ^worker_id}} when not is_nil(worker) ->
                {:error, :worker_session_offline}

              _other ->
                {:error, :worker_session_not_found}
            end

          {result, record_call(state, {:fresh_worker_session, worker_id, session_id, opts})}
        end)
      end

      defp fresh_session_result(worker, session, cutoff) do
        if DateTime.compare(session.last_heartbeat_at, cutoff) in [:eq, :gt],
          do: {:ok, worker, session},
          else: {:error, :worker_session_stale}
      end

      def heartbeat_worker(worker_id, session_id) do
        ensure_started()

        with {:ok, _worker, _session} <- active_worker_session(worker_id, session_id) do
          Agent.update(@name, &record_call(&1, {:heartbeat_worker, worker_id, session_id}))
          {:ok, %{ok: true, server_time: DateTime.utc_now()}}
        end
      end

      def expire_stale_worker_sessions(_opts \\ []), do: 0

      def export_workflow(workflow) do
        loaded = %{
          config: Map.get(workflow, :yaml_config, %{}),
          prompt: Map.get(workflow, :prompt_body, "")
        }

        with {:ok, project_config} <- WorkflowScopes.project_from_loaded(loaded) do
          {:ok, SymphonyElixir.Workflow.to_markdown(project_config, "")}
        end
      end

      def export_package(instance, workflow) do
        project = project_for_workflow(workflow)
        project_config = ProjectAuthority.strip(Map.fetch!(workflow, :yaml_config))

        with {:ok, loaded} <- WorkflowScopes.combined(instance, project_config) do
          portable = ProjectAuthority.inject(loaded.config, project)
          {:ok, SymphonyElixir.Workflow.to_markdown(portable, loaded.prompt)}
        end
      end

      def repo_available? do
        :symphony_elixir
        |> Application.get_env(:fake_persistence, [])
        |> Keyword.get(:repo_available?, false)
      end

      def get_run(id) do
        ensure_started()
        Agent.get(@name, fn state -> Enum.find(state.runs, &(Map.get(&1, :id) == id)) end)
      end

      def update_run(run, attrs) when is_map(run) and is_map(attrs) do
        ensure_started()
        id = Map.get(run, :id)

        Agent.get_and_update(@name, fn state ->
          updated = Map.merge(run, atomize_keys(attrs))
          runs = Enum.map(state.runs, &replace_run(&1, id, updated))

          {{:ok, updated}, state |> record_call({:update_run, run, attrs}) |> Map.put(:runs, runs)}
        end)
      end

      defp replace_run(existing, id, updated) do
        if Map.get(existing, :id) == id, do: updated, else: existing
      end

      defp sort_runs(runs) do
        Enum.sort(runs, fn left, right ->
          case DateTime.compare(run_inserted_at(left), run_inserted_at(right)) do
            :gt -> true
            :lt -> false
            :eq -> to_string(Map.get(left, :id)) >= to_string(Map.get(right, :id))
          end
        end)
      end

      defp apply_run_cursor(runs, nil), do: runs
      defp apply_run_cursor(runs, ""), do: runs

      defp apply_run_cursor(runs, cursor) when is_binary(cursor) do
        case decode_fake_run_cursor(cursor) do
          {:ok, inserted_at, id} ->
            Enum.filter(runs, fn run ->
              run_inserted_at = run_inserted_at(run)
              run_id = Map.get(run, :id)

              DateTime.compare(run_inserted_at, inserted_at) == :lt or
                (DateTime.compare(run_inserted_at, inserted_at) == :eq and run_id < id)
            end)

          :error ->
            runs
        end
      end

      defp fake_run_cursor(_run, false), do: nil
      defp fake_run_cursor(nil, _has_more), do: nil

      defp fake_run_cursor(run, true) do
        encoded =
          Jason.encode!(%{
            "inserted_at" => DateTime.to_iso8601(run_inserted_at(run)),
            "id" => Map.get(run, :id)
          })

        Base.url_encode64(encoded, padding: false)
      end

      defp decode_fake_run_cursor(cursor) do
        with {:ok, json} <- Base.url_decode64(cursor, padding: false),
             {:ok, %{"inserted_at" => inserted_at, "id" => id}} <- Jason.decode(json),
             {:ok, datetime, _offset} <- DateTime.from_iso8601(inserted_at),
             true <- is_binary(id) do
          {:ok, datetime, id}
        else
          _ -> :error
        end
      end

      defp run_inserted_at(%{inserted_at: %DateTime{} = inserted_at}), do: inserted_at
      defp run_inserted_at(%{started_at: %DateTime{} = started_at}), do: started_at
      defp run_inserted_at(_run), do: ~U[1970-01-01 00:00:00Z]

      def finish_run(run_id, status, terminal, opts \\ []) do
        SymphonyElixir.RunLifecycle.finish_run(__MODULE__, run_id, status, terminal, opts)
      end

      def list_runs_for_issue(identifier, _opts \\ []) do
        ensure_started()

        Agent.get(@name, fn state ->
          Enum.filter(state.runs, &(Map.get(&1, :issue_identifier) == identifier))
        end)
      end

      def get_user(username) do
        ensure_started()
        Agent.get(@name, fn state -> Map.get(state.users, username) end)
      end

      def workflow_to_loaded(instance, record) do
        project = project_for_workflow(record)
        config = Map.fetch!(record, :yaml_config)

        project_config =
          case project do
            nil ->
              ProjectAuthority.strip(config)

            project ->
              ProjectAuthority.inject(ProjectAuthority.strip(config), project)
          end

        WorkflowScopes.compose(instance, project_config, record.project_id)
      end

      defp project_for_workflow(workflow) do
        ensure_started()

        Agent.get(@name, fn state ->
          Enum.find(state.projects, &(Map.get(&1, :id) == workflow.project_id)) || hd(state.projects)
        end)
      end

      defp select_current_workflow(state) do
        state.projects
        |> Enum.filter(&runtime_project?/1)
        |> current_project_workflows(state.workflows)
        |> select_current_project_workflow()
      end

      defp current_project_workflows(projects, workflows) do
        projects
        |> Enum.flat_map(fn project ->
          case Enum.find(workflows, &(Map.get(&1, :project_id) == project.id)) do
            nil -> []
            workflow -> [{project, workflow}]
          end
        end)
      end

      defp select_current_project_workflow(project_workflows) do
        case Enum.find(project_workflows, fn {project, _workflow} -> configured_default_project?(project) end) do
          {_project, workflow} ->
            workflow

          nil ->
            case project_workflows do
              [] -> nil
              [{_project, workflow}] -> workflow
              _multiple -> {:error, :missing_project_context}
            end
        end
      end

      defp configured_default_project?(project), do: Map.get(project, :slug) == "default"

      defp runtime_project?(project) do
        Map.get(project, :enabled, true) == true and bootstrap_default_placeholder?(project) == false
      end

      defp bootstrap_default_placeholder?(project) do
        Map.get(project, :slug) == "default" and text_blank?(Map.get(project, :repository_url))
      end

      defp text_blank?(value) when is_binary(value), do: String.trim(value) == ""
      defp text_blank?(nil), do: true
      defp text_blank?(_value), do: false

      defp validate_project_authority(project, config) do
        case ProjectAuthority.conflicts(project, config) do
          [] -> :ok
          conflicts -> {:error, {:project_authority_conflict, conflicts}}
        end
      end

      def worker_heartbeat_interval_seconds, do: 10

      def worker_lease_duration_seconds, do: 60

      def worker_protocol_version, do: "worker-api-v1"

      def valid_worker_registration_token?(token) do
        :symphony_elixir
        |> Application.get_env(:worker_api, [])
        |> Keyword.get(:registration_token)
        |> then(&(&1 == token))
      end

      def register_worker(attrs) do
        ensure_started()
        now = DateTime.utc_now()
        worker_id = "fake-worker-#{System.unique_integer([:positive])}"
        session_id = "fake-session-#{System.unique_integer([:positive])}"

        worker = %{
          id: worker_id,
          name: Map.get(attrs, "worker_name", worker_id),
          status: "online",
          labels: Map.get(attrs, "labels", []),
          last_seen_at: now
        }

        session = %{
          id: session_id,
          worker_id: worker_id,
          status: "online",
          total_slots: Map.fetch!(attrs, "total_slots"),
          last_heartbeat_at: now
        }

        Agent.update(@name, fn state ->
          state
          |> record_call({:register_worker, attrs})
          |> update_in([:workers], &[worker | &1])
          |> update_in([:worker_sessions], &[session | &1])
        end)

        {:ok, %{worker: worker, session: session}}
      end

      def claim_task(worker_id, session_id, params) do
        ensure_started()
        Agent.update(@name, &record_call(&1, {:claim_task, worker_id, session_id, params}))
        {:ok, nil}
      end

      def heartbeat(worker_id, session_id, params) do
        ensure_started()
        Agent.update(@name, &record_call(&1, {:heartbeat, worker_id, session_id, params}))
        {:ok, %{ok: true, lease_renewals: []}}
      end

      def record_worker_task_event(worker_id, session_id, task_id, event_type, payload) do
        ensure_started()
        event = %{id: "fake-event-#{System.unique_integer([:positive])}"}

        Agent.update(
          @name,
          &record_call(
            &1,
            {:record_worker_task_event, worker_id, session_id, task_id, event_type, payload}
          )
        )

        {:ok, event}
      end

      defp initial_state do
        %{
          calls: [],
          projects: [
            %{
              id: "fake-project-id",
              name: "Fake Project",
              slug: "fake",
              linear_project_slug: "project",
              repository_url: "git@github.com:org/repo.git",
              default_branch: "main",
              checkout_depth: 1,
              source_strategy: "clone",
              worktree_fetch: true,
              worktree_cleanup: true,
              description: nil,
              enabled: true
            }
          ],
          runs: [],
          events: [],
          workers: [],
          worker_sessions: [],
          issues: [],
          workflows: [],
          instance_workflow: nil,
          legacy_instance_workflow_candidates: nil,
          next_legacy_reconciliation_error: nil,
          next_import_workflow_error: nil,
          next_runtime_publication_error: nil,
          runtime_publication_count: 0,
          users: %{}
        }
      end

      defp ensure_started do
        case Process.whereis(@name) do
          nil -> Agent.start(fn -> initial_state() end, name: @name)
          _pid -> :ok
        end
      end

      defp maybe_publish_runtime do
        failure =
          Agent.get_and_update(@name, fn state ->
            next_state =
              state
              |> Map.update!(:runtime_publication_count, &(&1 + 1))
              |> Map.put(:next_runtime_publication_error, nil)

            {state.next_runtime_publication_error, next_state}
          end)

        case failure do
          nil ->
            if Process.whereis(SymphonyElixir.WorkflowStore) do
              SymphonyElixir.WorkflowStore.force_reload()
            else
              :ok
            end

          reason ->
            {:error, reason}
        end
      end

      defp reconcile_legacy_state(%{instance_workflow: instance} = state, _project_slug)
           when is_map(instance) do
        {{:ok, {:already_converged, instance}}, state}
      end

      defp reconcile_legacy_state(%{legacy_instance_workflow_candidates: nil} = state, _project_slug) do
        {{:error, :zero}, state}
      end

      defp reconcile_legacy_state(state, project_slug) do
        case LegacyWorkflowConvergence.select_candidate(
               state.legacy_instance_workflow_candidates,
               project_slug
             ) do
          {:ok, instance} ->
            next_state =
              state
              |> Map.put(:instance_workflow, instance)
              |> Map.put(:legacy_instance_workflow_candidates, nil)

            {{:ok, {:converged, instance}}, next_state}

          {:error, _reason} = error ->
            {error, state}
        end
      end

      defp put_workflow_record(workflows, nil), do: workflows

      defp put_workflow_record(workflows, workflow) do
        [workflow | reject_by_project_id(workflows, Map.get(workflow, :project_id))]
      end

      defp reject_by_id(records, id), do: Enum.reject(records, &(Map.get(&1, :id) == id))

      defp reject_by_project_id(records, project_id) do
        Enum.reject(records, &(Map.get(&1, :project_id) == project_id))
      end

      defp record_call(state, call), do: update_in(state.calls, &[call | &1])

      defp replace_project(projects, id, updated) do
        Enum.map(projects, fn
          %{id: ^id} -> updated
          other -> other
        end)
      end

      defp atomize_project_attrs(attrs) do
        %{
          name: project_attr(attrs, :name),
          slug: project_attr(attrs, :slug),
          linear_project_slug: project_attr(attrs, :linear_project_slug),
          repository_url: project_attr(attrs, :repository_url),
          default_branch: project_attr(attrs, :default_branch, "main"),
          checkout_depth: project_attr(attrs, :checkout_depth, 1),
          source_strategy: project_attr(attrs, :source_strategy, "clone"),
          worktree_fetch: project_attr(attrs, :worktree_fetch, true),
          worktree_cleanup: project_attr(attrs, :worktree_cleanup, true),
          description: project_attr(attrs, :description),
          enabled: project_attr(attrs, :enabled, true),
          after_create_hook: project_attr(attrs, :after_create_hook),
          before_run_hook: project_attr(attrs, :before_run_hook),
          after_run_hook: project_attr(attrs, :after_run_hook),
          before_remove_hook: project_attr(attrs, :before_remove_hook)
        }
      end

      defp project_attr(attrs, key, default \\ nil) do
        Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
      end

      defp filter_eq(values, _key, nil), do: values
      defp filter_eq(values, _key, ""), do: values

      defp filter_eq(values, key, expected) do
        Enum.filter(values, &(Map.get(&1, key) == expected))
      end

      defp sort_events(events, :asc), do: Enum.sort_by(events, &event_time_sort_key/1)
      defp sort_events(events, "asc"), do: Enum.sort_by(events, &event_time_sort_key/1)
      defp sort_events(events, _order), do: events

      defp event_time_sort_key(event) do
        case Map.get(event, :occurred_at) do
          %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
          _ -> 0
        end
      end

      defp atomize_keys(attrs) do
        Map.new(attrs, fn
          {key, value} when is_binary(key) -> {fixture_key(key), value}
          pair -> pair
        end)
      end

      defp admission_issue(issues, attrs) do
        existing =
          Enum.find(issues, fn issue ->
            Map.get(issue, :project_id) == Map.fetch!(attrs, :project_id) and
              Map.get(issue, :identifier) == Map.fetch!(attrs, :identifier)
          end)

        Map.merge(existing || %{id: "fake-issue-#{System.unique_integer([:positive])}"}, attrs)
      end

      defp replaceable_orphan?(%{started_at: %DateTime{} = started_at}, %DateTime{} = cutoff, opts) do
        Keyword.get(opts, :manual_rerun?, false) and DateTime.compare(started_at, cutoff) == :lt
      end

      defp replaceable_orphan?(_run, _cutoff, _opts), do: false

      defp replace_fake_orphan(runs, events, nil, _issue, _now), do: {runs, events, nil}

      defp replace_fake_orphan(runs, events, active_run, issue, now) do
        failure =
          SymphonyElixir.RunFailure.classify({:assignment_expired, %{reason: "operator_manual_rerun", phase: "admission", prior_run_id: active_run.id}})

        terminal = SymphonyElixir.RunLifecycle.terminal_attrs("failed", failure, now)
        replaced = Map.merge(active_run, terminal)
        runs = Enum.map(runs, fn run -> if run.id == active_run.id, do: replaced, else: run end)

        event = %{
          id: "event-#{System.unique_integer([:positive])}",
          project_id: issue.project_id,
          run_id: replaced.id,
          issue_identifier: issue.identifier,
          event_type: "run.failed",
          payload: %{"failure_reason" => terminal.failure_reason, "failure_evidence" => terminal.failure_evidence},
          occurred_at: now
        }

        {runs, [event | events], replaced}
      end

      @fixture_keys %{
        "id" => :id,
        "kind" => :kind,
        "profile" => :profile,
        "label" => :label,
        "project_id" => :project_id,
        "issue_id" => :issue_id,
        "issue_identifier" => :issue_identifier,
        "workspace_path" => :workspace_path,
        "status" => :status,
        "execution_mode" => :execution_mode,
        "attempt" => :attempt,
        "failure_reason" => :failure_reason,
        "failure_evidence" => :failure_evidence,
        "execution_summary" => :execution_summary,
        "started_at" => :started_at,
        "finished_at" => :finished_at,
        "inserted_at" => :inserted_at,
        "updated_at" => :updated_at
      }

      defp fixture_key(key), do: Map.fetch!(@fixture_keys, key)

      defp reject_project_hook_fields(attrs) do
        hook_fields = [
          {:after_create_hook, "after_create_hook"},
          {:before_run_hook, "before_run_hook"},
          {:after_run_hook, "after_run_hook"},
          {:before_remove_hook, "before_remove_hook"}
        ]

        instance_fields =
          attrs
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.filter(&(&1 in (WorkflowScopes.instance_sections() ++ ["prompt_body", "workflow"])))

        hook_fields =
          hook_fields
          |> Enum.filter(fn {atom_field, string_field} ->
            value = Map.get(attrs, atom_field, Map.get(attrs, string_field))
            is_binary(value) and String.trim(value) != ""
          end)
          |> Enum.map(&elem(&1, 1))

        invalid = Enum.sort(Enum.uniq(instance_fields ++ hook_fields))

        if invalid == [], do: :ok, else: {:error, {:out_of_scope_project_fields, invalid}}
      end
    end
  end
end

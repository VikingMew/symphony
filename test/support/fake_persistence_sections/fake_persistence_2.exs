# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.FakePersistence.Sections.FakePersistence2 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      alias SymphonyElixir.Config.{LegacyWorkflowConvergence, WorkflowScopes}

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
        if DateTime.compare(session.last_heartbeat_at, cutoff) in [:eq, :gt] do
          {:ok, worker, session}
        else
          {:error, :worker_session_stale}
        end
      end

      def heartbeat_worker(worker_id, session_id) do
        ensure_started()

        with {:ok, _worker, _session} <- active_worker_session(worker_id, session_id) do
          Agent.update(@name, &record_call(&1, {:heartbeat_worker, worker_id, session_id}))
          {:ok, %{ok: true, server_time: DateTime.utc_now()}}
        end
      end

      def expire_stale_worker_sessions(_opts \\ []) do
        0
      end

      def export_workflow(workflow) do
        loaded = %{
          config: Map.get(workflow, :yaml_config, %{}),
          prompt: Map.get(workflow, :prompt_body, "")
        }

        with {:ok, project_config} <-
               Elixir.SymphonyElixir.Config.WorkflowScopes.project_from_loaded(loaded) do
          {:ok, SymphonyElixir.Workflow.to_markdown(project_config, "")}
        end
      end

      def export_package(instance, workflow) do
        project_config =
          apply_project_runtime_settings(
            Map.fetch!(workflow, :yaml_config),
            project_for_workflow(workflow)
          )

        with {:ok, loaded} <-
               Elixir.SymphonyElixir.Config.WorkflowScopes.combined(instance, project_config) do
          {:ok, SymphonyElixir.Workflow.to_markdown(loaded.config, loaded.prompt)}
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
        if Map.get(existing, :id) == id do
          updated
        else
          existing
        end
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

      defp apply_run_cursor(runs, nil) do
        runs
      end

      defp apply_run_cursor(runs, "") do
        runs
      end

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

      defp fake_run_cursor(_run, false) do
        nil
      end

      defp fake_run_cursor(nil, _has_more) do
        nil
      end

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

      defp run_inserted_at(%{inserted_at: %DateTime{} = inserted_at}) do
        inserted_at
      end

      defp run_inserted_at(%{started_at: %DateTime{} = started_at}) do
        started_at
      end

      defp run_inserted_at(_run) do
        ~U[1970-01-01 00:00:00Z]
      end

      def finish_run(run_id, status, failure_reason \\ nil, opts \\ []) do
        case get_run(run_id) do
          nil ->
            {:error, :not_found}

          run ->
            update_run(
              run,
              SymphonyElixir.RunLifecycle.terminal_attrs(
                status,
                failure_reason,
                Keyword.get(opts, :finished_at, DateTime.utc_now())
              )
            )
        end
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
        project_config = apply_project_runtime_settings(Map.fetch!(record, :yaml_config), project)

        Elixir.SymphonyElixir.Config.WorkflowScopes.compose(instance, project_config, record.project_id)
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
        case Enum.find(project_workflows, fn {project, _workflow} ->
               configured_default_project?(project)
             end) do
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

      defp configured_default_project?(project) do
        Map.get(project, :slug) == "default"
      end

      defp runtime_project?(project) do
        Map.get(project, :enabled, true) == true and bootstrap_default_placeholder?(project) == false
      end

      defp bootstrap_default_placeholder?(project) do
        Map.get(project, :slug) == "default" and text_blank?(Map.get(project, :repository_url))
      end

      defp text_blank?(value) when is_binary(value) do
        String.trim(value) == ""
      end

      defp text_blank?(nil) do
        true
      end

      defp text_blank?(_value) do
        false
      end

      defp apply_project_runtime_settings(config, nil) do
        config
      end

      defp apply_project_runtime_settings(config, project) do
        config
        |> put_in_path(["tracker", "project_slug"], Map.get(project, :linear_project_slug))
        |> update_project_config(project)
      end

      defp update_project_config(config, project) do
        existing = Map.get(config, "project", %{})

        project_config =
          existing
          |> put_project_value("repository_url", Map.get(project, :repository_url))
          |> put_project_value("default_branch", Map.get(project, :default_branch) || "main")
          |> put_project_value("checkout_depth", Map.get(project, :checkout_depth) || 1)
          |> put_project_value("source_strategy", Map.get(project, :source_strategy) || "clone")
          |> put_project_value("worktree_fetch", Map.get(project, :worktree_fetch) != false)
          |> put_project_value("worktree_cleanup", Map.get(project, :worktree_cleanup) != false)

        Map.put(config, "project", project_config)
      end

      defp put_project_value(config, key, value) when is_binary(value) do
        value = String.trim(value)

        if value == "" do
          Map.delete(config, key)
        else
          Map.put(config, key, value)
        end
      end

      defp put_project_value(config, key, nil) do
        Map.delete(config, key)
      end

      defp put_project_value(config, key, value) do
        Map.put(config, key, value)
      end

      defp put_in_path(config, path, value) do
        case is_nil(value) or (is_binary(value) and String.trim(value) == "") do
          true -> delete_in_path(config, path)
          false -> put_in(config, Enum.map(path, &Access.key(&1, %{})), value)
        end
      end

      defp delete_in_path(config, [key]) do
        Map.delete(config, key)
      end

      defp delete_in_path(config, [key | rest]) do
        case Map.get(config, key) do
          nested when is_map(nested) -> Map.put(config, key, delete_in_path(nested, rest))
          _ -> config
        end
      end

      def worker_heartbeat_interval_seconds do
        10
      end

      def worker_lease_duration_seconds do
        60
      end

      def worker_protocol_version do
        "worker-api-v1"
      end

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
        if Process.whereis(SymphonyElixir.WorkflowStore) do
          SymphonyElixir.WorkflowStore.force_reload()
        else
          :ok
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
        case Elixir.SymphonyElixir.Config.LegacyWorkflowConvergence.select_candidate(
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

      defp put_workflow_record(workflows, nil) do
        workflows
      end

      defp put_workflow_record(workflows, workflow) do
        [workflow | reject_by_project_id(workflows, Map.get(workflow, :project_id))]
      end

      defp reject_by_id(records, id) do
        Enum.reject(records, &(Map.get(&1, :id) == id))
      end

      defp reject_by_project_id(records, project_id) do
        Enum.reject(records, &(Map.get(&1, :project_id) == project_id))
      end

      defp record_call(state, call) do
        update_in(state.calls, &[call | &1])
      end

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

      defp filter_eq(values, _key, nil) do
        values
      end

      defp filter_eq(values, _key, "") do
        values
      end

      defp filter_eq(values, key, expected) do
        Enum.filter(values, &(Map.get(&1, key) == expected))
      end

      defp sort_events(events, :asc) do
        Enum.sort_by(events, &event_time_sort_key/1)
      end

      defp sort_events(events, "asc") do
        Enum.sort_by(events, &event_time_sort_key/1)
      end

      defp sort_events(events, _order) do
        events
      end

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
        "started_at" => :started_at,
        "finished_at" => :finished_at,
        "inserted_at" => :inserted_at,
        "updated_at" => :updated_at
      }

      defp fixture_key(key) do
        Map.fetch!(@fixture_keys, key)
      end

      defp reject_project_hook_fields(attrs) do
        hook_fields = [
          after_create_hook: "after_create_hook",
          before_run_hook: "before_run_hook",
          after_run_hook: "after_run_hook",
          before_remove_hook: "before_remove_hook"
        ]

        instance_fields =
          attrs
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.filter(
            &(&1 in (Elixir.SymphonyElixir.Config.WorkflowScopes.instance_sections() ++
                       ["prompt_body", "workflow"]))
          )

        hook_fields =
          hook_fields
          |> Enum.filter(fn {atom_field, string_field} ->
            value = Map.get(attrs, atom_field, Map.get(attrs, string_field))
            is_binary(value) and String.trim(value) != ""
          end)
          |> Enum.map(&elem(&1, 1))

        invalid = Enum.sort(Enum.uniq(instance_fields ++ hook_fields))

        if invalid == [] do
          :ok
        else
          {:error, {:out_of_scope_project_fields, invalid}}
        end
      end
    end
  end
end

# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.FakePersistence.Sections.FakePersistence1 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      @moduledoc false

      alias SymphonyElixir.Config.{LegacyWorkflowConvergence, ProjectAuthority, WorkflowScopes}
      alias SymphonyElixir.Persistence.Project

      @name __MODULE__

      def start_link(_opts \\ []) do
        Agent.start_link(fn -> initial_state() end, name: @name)
      end

      def reset!(state \\ initial_state()) do
        ensure_started()
        :ok = Agent.update(@name, fn _ -> state end)
        maybe_publish_runtime()
      end

      def calls do
        ensure_started()
        Agent.get(@name, & &1.calls)
      end

      def put_user(username, user) do
        ensure_started()
        Agent.update(@name, &put_in(&1.users[username], user))
      end

      def put_events(events) when is_list(events) do
        ensure_started()
        Agent.update(@name, &Map.put(&1, :events, events))
      end

      def put_runs(runs) when is_list(runs) do
        ensure_started()
        Agent.update(@name, &Map.put(&1, :runs, runs))
      end

      def put_issues(issues) when is_list(issues) do
        ensure_started()
        Agent.update(@name, &Map.put(&1, :issues, issues))
      end

      def upsert_issue(attrs) when is_map(attrs) do
        ensure_started()
        issue = Map.put_new(attrs, :id, "fake-issue-#{System.unique_integer([:positive])}")

        Agent.get_and_update(@name, fn state ->
          issues =
            state.issues
            |> Enum.reject(
              &(Map.get(&1, :project_id) == issue.project_id and
                  Map.get(&1, :tracker_issue_id) == issue.tracker_issue_id)
            )
            |> List.insert_at(0, issue)

          {{:ok, issue}, state |> record_call({:upsert_issue, attrs}) |> Map.put(:issues, issues)}
        end)
      end

      def get_issue_by_identifier(identifier) do
        ensure_started()

        Agent.get(@name, fn state ->
          Enum.find(state.issues, &(Map.get(&1, :identifier) == identifier))
        end)
      end

      def update_issue(issue, attrs) do
        ensure_started()
        updated = Map.merge(issue, attrs)

        Agent.update(@name, fn state ->
          Map.update!(state, :issues, &replace_issue(&1, issue, updated))
        end)

        {:ok, updated}
      end

      def compare_and_clear_blocking_decision(identifier, decision) do
        if hook = Application.get_env(:symphony_elixir, :blocking_decision_cas_hook) do
          hook.()
        end

        Agent.get_and_update(@name, fn state ->
          case Enum.find(state.issues, &(Map.get(&1, :identifier) == identifier)) do
            %{blocking_decision: ^decision} = issue ->
              updated = Map.merge(issue, %{blocking_decision: nil, no_progress_streak: 0})
              {{:ok, :cleared}, Map.update!(state, :issues, &replace_issue(&1, issue, updated))}

            _replaced ->
              {{:ok, :replaced}, state}
          end
        end)
      end

      defp replace_issue(issues, issue, updated) do
        Enum.map(issues, fn candidate ->
          if Map.get(candidate, :identifier) == Map.get(issue, :identifier),
            do: updated,
            else: candidate
        end)
      end

      def list_blocked_issues do
        ensure_started()

        Agent.get(@name, fn state ->
          Enum.filter(state.issues, &is_map(Map.get(&1, :blocking_decision)))
        end)
      end

      def list_analytics_issues do
        ensure_started()
        Agent.get(@name, & &1.issues)
      end

      def put_workflow(workflow) do
        ensure_started()

        :ok =
          Agent.update(@name, fn state ->
            Map.put(state, :workflows, put_workflow_record(state.workflows, workflow))
          end)

        maybe_publish_runtime()
      end

      def put_default_project_attrs!(attrs) when is_map(attrs) do
        ensure_started()

        :ok =
          Agent.update(@name, fn state ->
            [project | rest] = state.projects

            runtime_attrs =
              attrs
              |> atomize_project_attrs()
              |> Map.drop([:name, :slug, :description, :enabled])

            updated = Map.merge(project, runtime_attrs)
            Map.put(state, :projects, [updated | rest])
          end)

        maybe_publish_runtime()
      end

      def fail_next_import_workflow!(reason) do
        ensure_started()
        Agent.update(@name, &Map.put(&1, :next_import_workflow_error, reason))
      end

      def fail_next_runtime_publication!(reason) do
        ensure_started()
        Agent.update(@name, &Map.put(&1, :next_runtime_publication_error, reason))
      end

      def runtime_publication_count do
        ensure_started()
        Agent.get(@name, & &1.runtime_publication_count)
      end

      def default_project do
        ensure_started()
        Agent.get(@name, fn state -> {:ok, hd(state.projects)} end)
      end

      def import_workflow(project, raw_workflow_md, source) do
        ensure_started()

        with {:ok, loaded} <- SymphonyElixir.Workflow.parse_content(raw_workflow_md),
             {:ok, project_config} <- WorkflowScopes.project_from_loaded(loaded) do
          persist_project_workflow(project, project_config, source, :import_workflow)
        end
      end

      def save_project_settings(project_id, attrs, raw_workflow_md) do
        ensure_started()

        with :ok <- reject_project_hook_fields(attrs),
             {:ok, loaded} <- SymphonyElixir.Workflow.parse_content(raw_workflow_md),
             {:ok, project_config} <- WorkflowScopes.project_from_loaded(loaded) do
          result =
            Agent.get_and_update(
              @name,
              &save_project_settings_state(&1, project_id, attrs, project_config, raw_workflow_md)
            )

          publish_project_settings_result(result)
        end
      end

      defp save_project_settings_state(state, project_id, attrs, project_config, raw) do
        state = record_call(state, {:save_project_settings, project_id, attrs, raw})

        with {:ok, project, projects} <- stage_project(state.projects, project_id, attrs),
             nil <- state.next_import_workflow_error do
          workflow = project_workflow(project, project_config, "web_project_settings")
          saved = %{project: project, workflow: workflow}

          next_state =
            state
            |> Map.put(:projects, projects)
            |> Map.update!(:workflows, &put_workflow_record(&1, workflow))

          {{:ok, saved}, next_state}
        else
          {:error, reason} -> {{:error, reason}, state}
          reason -> {{:error, reason}, Map.put(state, :next_import_workflow_error, nil)}
        end
      end

      defp stage_project(projects, nil, attrs) do
        changeset = Project.changeset(%Project{}, attrs)

        if changeset.valid? do
          project = attrs |> atomize_project_attrs() |> Map.put(:id, "fake-project-#{System.unique_integer([:positive])}")
          {:ok, project, projects ++ [project]}
        else
          {:error, changeset}
        end
      end

      defp stage_project(projects, project_id, attrs) do
        case Enum.find(projects, &(Map.get(&1, :id) == project_id)) do
          nil ->
            {:error, :not_found}

          project ->
            changeset = Project.changeset(struct(Project, Map.take(project, Project.__schema__(:fields))), attrs)

            if changeset.valid? do
              updated = Map.merge(project, atomize_project_attrs(attrs))
              {:ok, updated, replace_project(projects, project_id, updated)}
            else
              {:error, changeset}
            end
        end
      end

      defp publish_project_settings_result({:ok, saved} = success) do
        case maybe_publish_runtime() do
          :ok -> success
          {:error, reason} -> {:error, {:runtime_publication_failed, saved, reason}}
        end
      end

      defp publish_project_settings_result(error), do: error

      def import_package(project, raw_workflow_md, source) do
        ensure_started()

        with {:ok, loaded} <- SymphonyElixir.Workflow.parse_content(raw_workflow_md),
             {:ok, instance, project_config} <- WorkflowScopes.split_package(loaded.config, loaded.prompt),
             :ok <- validate_project_authority(project, loaded.config) do
          workflow = project_workflow(project, project_config, source)

          result =
            Agent.get_and_update(
              @name,
              &import_package_state(&1, project, workflow, instance, source)
            )

          case result do
            {:ok, _scopes} ->
              maybe_publish_runtime()
              result

            error ->
              error
          end
        end
      end

      defp import_package_state(state, project, workflow, instance, source) do
        state = record_call(state, {:import_package, project, workflow.raw_workflow_md, source})

        case Map.get(state, :next_import_workflow_error) do
          nil ->
            next_state =
              state
              |> Map.update!(:workflows, &put_workflow_record(&1, workflow))
              |> Map.put(:instance_workflow, instance)

            {{:ok, %{instance_workflow: instance, project_workflow: workflow}}, next_state}

          reason ->
            {{:error, reason}, Map.put(state, :next_import_workflow_error, nil)}
        end
      end

      def put_instance_workflow(config, prompt_body) do
        with {:ok, instance} <- WorkflowScopes.new_instance(config, prompt_body) do
          Agent.update(@name, fn state ->
            state
            |> record_call({:put_instance_workflow, config, prompt_body})
            |> Map.put(:instance_workflow, instance)
          end)

          maybe_publish_runtime()
          {:ok, instance}
        end
      end

      def put_package_unchecked(project, config, prompt_body) do
        instance = %{
          config: Map.take(config, WorkflowScopes.instance_sections()),
          prompt_body: prompt_body
        }

        project_config =
          config
          |> Map.take(WorkflowScopes.project_sections())
          |> update_in([Access.key("tracker", %{})], &Map.delete(&1, "api_key"))

        workflow = project_workflow(project, project_config, "test")

        Agent.update(@name, fn state ->
          state
          |> Map.update!(:workflows, &put_workflow_record(&1, workflow))
          |> Map.put(:instance_workflow, instance)
        end)

        maybe_publish_runtime()
        {:ok, %{instance_workflow: instance, project_workflow: workflow}}
      end

      def instance_workflow do
        ensure_started()
        Agent.get(@name, & &1.instance_workflow)
      end

      def put_legacy_instance_workflow_conflict!(conflict) do
        ensure_started()

        Agent.update(@name, fn state ->
          state
          |> Map.put(:instance_workflow, nil)
          |> Map.put(:legacy_instance_workflow_candidates, conflict)
        end)
      end

      def fail_next_legacy_reconciliation!(reason) do
        ensure_started()
        Agent.update(@name, &Map.put(&1, :next_legacy_reconciliation_error, reason))
      end

      def legacy_instance_workflow_status do
        ensure_started()

        Agent.get(@name, fn state ->
          instance =
            case state.instance_workflow do
              nil -> nil
              value -> WorkflowScopes.dump_instance(value)
            end

          LegacyWorkflowConvergence.status(instance, state.legacy_instance_workflow_candidates)
        end)
      end

      def reconcile_legacy_instance_workflow_durable(project_slug) do
        ensure_started()

        Agent.get_and_update(@name, fn state ->
          state = record_call(state, {:reconcile_legacy_instance_workflow, project_slug})

          case state.next_legacy_reconciliation_error do
            nil -> reconcile_legacy_state(state, project_slug)
            reason -> {{:error, {:transaction_failed, reason}}, %{state | next_legacy_reconciliation_error: nil}}
          end
        end)
      end

      def reconcile_legacy_instance_workflow(project_slug) do
        project_slug
        |> reconcile_legacy_instance_workflow_durable()
        |> SymphonyElixir.PersistenceProvider.publish_runtime_mutation()
      end

      defp persist_project_workflow(project, project_config, source, operation) do
        workflow = project_workflow(project, project_config, source)

        result =
          Agent.get_and_update(@name, fn state ->
            state = record_call(state, {operation, project, workflow.raw_workflow_md, source})

            case Map.get(state, :next_import_workflow_error) do
              nil ->
                next_state = Map.update!(state, :workflows, &put_workflow_record(&1, workflow))

                {{:ok, workflow}, next_state}

              reason ->
                {{:error, reason}, Map.put(state, :next_import_workflow_error, nil)}
            end
          end)

        if match?({:ok, _workflow}, result), do: maybe_publish_runtime()
        result
      end

      defp project_workflow(project, project_config, source) do
        %{
          id: "fake-workflow-#{Map.get(project, :slug) || "project"}",
          project_id: project.id,
          source: source,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now(),
          raw_workflow_md: SymphonyElixir.Workflow.to_markdown(project_config, ""),
          yaml_config: project_config,
          prompt_body: ""
        }
      end

      def current_workflow do
        ensure_started()
        Agent.get(@name, &select_current_workflow/1)
      end

      def current_workflow(%{id: project_id}) do
        ensure_started()

        Agent.get(@name, fn state ->
          Enum.find(state.workflows, &(Map.get(&1, :project_id) == project_id))
        end)
      end

      def current_workflow(_project) do
        current_workflow()
      end

      def list_projects do
        ensure_started()
        Agent.get(@name, & &1.projects)
      end

      def create_project(attrs) do
        ensure_started()

        with :ok <- reject_project_hook_fields(attrs) do
          do_create_project(attrs)
        end
      end

      defp do_create_project(attrs) do
        result =
          Agent.get_and_update(@name, fn state ->
            project =
              attrs
              |> atomize_project_attrs()
              |> Map.put(:id, "fake-project-#{System.unique_integer([:positive])}")

            {{:ok, project},
             state
             |> record_call({:create_project, attrs})
             |> Map.update!(:projects, &(&1 ++ [project]))}
          end)

        maybe_publish_runtime()
        result
      end

      def update_project(id, attrs) do
        ensure_started()

        with :ok <- reject_project_hook_fields(attrs) do
          do_update_project(id, attrs)
        end
      end

      defp do_update_project(id, attrs) do
        result =
          Agent.get_and_update(@name, fn state ->
            case Enum.find(state.projects, &(Map.get(&1, :id) == id)) do
              nil ->
                {{:error, :not_found}, state |> record_call({:update_project, id, attrs})}

              project ->
                updated = Map.merge(project, atomize_project_attrs(attrs))
                projects = replace_project(state.projects, id, updated)

                {{:ok, updated}, state |> record_call({:update_project, id, attrs}) |> Map.put(:projects, projects)}
            end
          end)

        if match?({:ok, _project}, result), do: maybe_publish_runtime()
        result
      end

      def delete_project(id) do
        ensure_started()

        result =
          Agent.get_and_update(@name, fn state ->
            case Enum.find(state.projects, &(Map.get(&1, :id) == id)) do
              nil ->
                {{:error, :not_found}, record_call(state, {:delete_project, id})}

              project ->
                next_state =
                  state
                  |> record_call({:delete_project, id})
                  |> Map.update!(:projects, &reject_by_id(&1, id))
                  |> Map.update!(:workflows, &reject_by_project_id(&1, id))

                {{:ok, project}, next_state}
            end
          end)

        if match?({:ok, _project}, result), do: maybe_publish_runtime()
        result
      end

      def list_runs(opts \\ []) do
        ensure_started()

        Agent.get(@name, fn state ->
          state.runs
          |> filter_eq(:status, Keyword.get(opts, :status))
          |> filter_eq(:kind, Keyword.get(opts, :kind))
          |> filter_eq(:project_id, Keyword.get(opts, :project_id))
          |> sort_runs()
          |> Enum.take(Keyword.get(opts, :limit, length(state.runs)))
        end)
      end

      def list_analytics_runs do
        ensure_started()
        Agent.get(@name, & &1.runs)
      end

      def list_runs_page(opts \\ []) do
        ensure_started()
        page_size = opts |> Keyword.get(:page_size, 25) |> max(1)
        cursor = Keyword.get(opts, :cursor)

        Agent.get(@name, fn state ->
          runs =
            state.runs
            |> filter_eq(:status, Keyword.get(opts, :status))
            |> filter_eq(:kind, Keyword.get(opts, :kind))
            |> filter_eq(:project_id, Keyword.get(opts, :project_id))
            |> sort_runs()
            |> apply_run_cursor(cursor)

          {entries, overflow} = runs |> Enum.take(page_size + 1) |> Enum.split(page_size)

          %{
            entries: entries,
            has_more?: overflow != [],
            next_cursor: fake_run_cursor(List.last(entries), overflow != [])
          }
        end)
      end

      def create_run(attrs) when is_map(attrs) do
        ensure_started()

        run =
          attrs
          |> atomize_keys()
          |> Map.put_new(:id, "run-#{System.unique_integer([:positive])}")
          |> Map.put_new(:kind, "issue")
          |> Map.put_new(:status, "running")
          |> Map.put_new(:attempt, 0)
          |> Map.put_new(:started_at, DateTime.utc_now())
          |> Map.put_new(:inserted_at, DateTime.utc_now())
          |> Map.put_new(:updated_at, DateTime.utc_now())

        Agent.get_and_update(@name, fn state ->
          {{:ok, run}, state |> record_call({:create_run, attrs}) |> Map.update!(:runs, &[run | &1])}
        end)
      end

      def admit_issue_run(issue_attrs, run_attrs, opts \\ []) do
        ensure_started()

        if hook = Application.get_env(:symphony_elixir, :fake_admit_run_hook) do
          hook.()
        end

        Agent.get_and_update(@name, fn state ->
          issue = admission_issue(state.issues, issue_attrs)
          active_run = Enum.find(state.runs, &(Map.get(&1, :issue_id) == issue.id and Map.get(&1, :status) == "running"))
          cutoff = Keyword.get(opts, :orphan_cutoff)

          if active_run && not replaceable_orphan?(active_run, cutoff, opts) do
            {{:error, {:active_run, active_run.id}}, record_call(state, {:admit_issue_run, issue_attrs, run_attrs})}
          else
            now = Keyword.get(opts, :now, DateTime.utc_now())
            {runs, events, replaced_run} = replace_fake_orphan(state.runs, state.events, active_run, issue, now)

            run =
              run_attrs
              |> atomize_keys()
              |> Map.put(:issue_id, issue.id)
              |> Map.put_new(:project_id, issue.project_id)
              |> Map.put_new(:id, "run-#{System.unique_integer([:positive])}")
              |> Map.put_new(:kind, "issue")
              |> Map.put_new(:status, "running")
              |> Map.put_new(:attempt, 0)
              |> Map.put_new(:started_at, now)
              |> Map.put_new(:inserted_at, now)
              |> Map.put_new(:updated_at, now)

            next_state =
              state
              |> record_call({:admit_issue_run, issue_attrs, run_attrs})
              |> Map.put(:issues, [issue | Enum.reject(state.issues, &(Map.get(&1, :project_id) == issue.project_id and Map.get(&1, :identifier) == issue.identifier))])
              |> Map.put(:runs, [run | runs])
              |> Map.put(:events, events)

            {{:ok, %{issue: issue, run: run, replaced_run: replaced_run}}, next_state}
          end
        end)
      end
    end
  end
end

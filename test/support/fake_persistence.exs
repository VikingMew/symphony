defmodule SymphonyElixir.TestSupport.FakePersistence do
  @moduledoc false

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

  def put_tasks(tasks) when is_list(tasks) do
    ensure_started()
    Agent.update(@name, &Map.put(&1, :tasks, tasks))
  end

  def put_cancel_task_errors(errors) when is_map(errors) do
    ensure_started()
    Agent.update(@name, &Map.put(&1, :cancel_task_errors, errors))
  end

  def put_issues(issues) when is_list(issues) do
    ensure_started()
    Agent.update(@name, &Map.put(&1, :issues, issues))
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

  def default_project do
    ensure_started()
    Agent.get(@name, fn state -> {:ok, hd(state.projects)} end)
  end

  def import_workflow(project, raw_workflow_md, source) do
    ensure_started()

    workflow = %{
      id: "fake-workflow-#{Map.get(project, :slug) || "project"}",
      project_id: project.id,
      source: source,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      raw_workflow_md: raw_workflow_md
    }

    result =
      Agent.get_and_update(@name, fn state ->
        state = record_call(state, {:import_workflow, project, raw_workflow_md, source})

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

  def current_workflow do
    ensure_started()
    Agent.get(@name, fn state -> List.first(state.workflows) end)
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

  def available_worker_slots(_opts \\ []) do
    ensure_started()

    Agent.get(@name, fn state ->
      capacity =
        state.worker_sessions
        |> Enum.filter(&(Map.get(&1, :status) == "online"))
        |> Enum.sum_by(&Map.fetch!(&1, :total_slots))

      occupied =
        Enum.count(state.tasks, fn task ->
          Map.get(task, :execution_mode, "worker") == "worker" and
            Map.get(task, :status) in ["queued", "leased", "running"]
        end)

      max(capacity - occupied, 0)
    end)
  end

  def list_tasks(opts \\ []) do
    ensure_started()

    Agent.get(@name, fn state ->
      state.tasks
      |> filter_eq(:project_id, Keyword.get(opts, :project_id))
    end)
  end

  def list_task_leases(_opts \\ []) do
    ensure_started()
    Agent.get(@name, & &1.task_leases)
  end

  def export_workflow(%{raw_workflow_md: raw}), do: raw

  def cancel_task(id, reason \\ "cancelled") do
    ensure_started()
    task = %{id: id, status: "cancelled", payload: %{"reason" => reason}}

    Agent.get_and_update(@name, fn state ->
      state = record_call(state, {:cancel_task, id, reason})

      case Map.fetch(state.cancel_task_errors, id) do
        {:ok, error} -> {{:error, error}, state}
        :error -> {{:ok, task}, state}
      end
    end)
  end

  def requeue_task(id) do
    ensure_started()
    task = %{id: id, status: "queued"}
    Agent.update(@name, &record_call(&1, {:requeue_task, id}))
    {:ok, task}
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

  def workflow_to_loaded(record) do
    {:ok, workflow} = SymphonyElixir.Workflow.parse_content(record.raw_workflow_md)
    project = project_for_workflow(record)

    workflow
    |> Map.update!(:config, &apply_project_runtime_settings(&1, project))
    |> Map.put(:project_id, record.project_id)
  end

  defp project_for_workflow(workflow) do
    ensure_started()

    Agent.get(@name, fn state ->
      Enum.find(state.projects, &(Map.get(&1, :id) == workflow.project_id)) || hd(state.projects)
    end)
  end

  defp apply_project_runtime_settings(config, nil), do: config

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

    config
    |> Map.put("project", project_config)
    |> apply_project_hooks(project)
  end

  defp apply_project_hooks(config, project) do
    [
      {"after_create", Map.get(project, :after_create_hook)},
      {"before_run", Map.get(project, :before_run_hook)},
      {"after_run", Map.get(project, :after_run_hook)},
      {"before_remove", Map.get(project, :before_remove_hook)}
    ]
    |> Enum.reduce(config, fn {key, value}, acc ->
      if is_binary(value) and String.trim(value) != "" do
        hooks = Map.get(acc, "hooks", %{})
        Map.put(acc, "hooks", Map.put(hooks, key, value))
      else
        acc
      end
    end)
  end

  defp put_project_value(config, key, value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: Map.delete(config, key), else: Map.put(config, key, value)
  end

  defp put_project_value(config, key, nil), do: Map.delete(config, key)
  defp put_project_value(config, key, value), do: Map.put(config, key, value)

  defp put_in_path(config, path, value) do
    case is_nil(value) or (is_binary(value) and String.trim(value) == "") do
      true -> delete_in_path(config, path)
      false -> put_in(config, Enum.map(path, &Access.key(&1, %{})), value)
    end
  end

  defp delete_in_path(config, [key]), do: Map.delete(config, key)

  defp delete_in_path(config, [key | rest]) do
    case Map.get(config, key) do
      nested when is_map(nested) -> Map.put(config, key, delete_in_path(nested, rest))
      _ -> config
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
      tasks: [],
      cancel_task_errors: %{},
      task_leases: [],
      issues: [],
      workflows: [],
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

  defp fixture_key(key), do: Map.fetch!(@fixture_keys, key)
end

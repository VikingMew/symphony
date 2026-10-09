defmodule SymphonyElixir.TestSupport.SettingsFakePersistenceSupport do
  import ExUnit.Callbacks

  alias Elixir.SymphonyElixirWeb.Endpoint
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.TestSupport.WorkflowFixtures

  defmodule FakeLinearClient do
    @moduledoc false

    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    defdelegate graphql(query, variables, opts),
      to: SymphonyElixir.TestSupport.SettingsFakePersistenceSupport,
      as: :fake_graphql

    @spec fetch_candidate_issues() :: {:ok, list()}
    defdelegate fetch_candidate_issues(),
      to: SymphonyElixir.TestSupport.SettingsFakePersistenceSupport,
      as: :empty_candidate_result
  end

  defmodule NoDefaultPersistence do
    @moduledoc false
    def default_project do
      {:error, :not_found}
    end

    defdelegate instance_workflow(), to: SymphonyElixir.TestSupport.FakePersistence

    defdelegate put_instance_workflow(config, prompt),
      to: SymphonyElixir.TestSupport.FakePersistence

    defdelegate legacy_instance_workflow_status(), to: SymphonyElixir.TestSupport.FakePersistence

    defdelegate reconcile_legacy_instance_workflow(slug),
      to: SymphonyElixir.TestSupport.FakePersistence

    defdelegate list_projects(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate current_workflow(project), to: SymphonyElixir.TestSupport.FakePersistence

    defdelegate workflow_to_loaded(instance, version),
      to: SymphonyElixir.TestSupport.FakePersistence

    defdelegate export_workflow(version), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_runs_page(opts), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_events(opts), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate delete_project(id), to: SymphonyElixir.TestSupport.FakePersistence
  end

  def fake_graphql(_query, variables, opts) do
    fake = Application.get_env(:symphony_elixir, :linear_discovery_fake, %{})

    case Map.get(fake, Keyword.get(opts, :operation_name)) do
      nil -> {:ok, fake_default_response(Keyword.get(opts, :operation_name), variables)}
      {:error, reason} -> {:error, reason}
      response -> {:ok, response}
    end
  end

  @spec empty_candidate_result() :: {:ok, list()}
  def empty_candidate_result, do: {:ok, []}

  def busy_init(opts) do
    {:ok, Keyword.fetch!(opts, :snapshot)}
  end

  def busy_handle_call(:snapshot, _from, snapshot) do
    {:reply, snapshot, snapshot}
  end

  def busy_handle_call({:request_operator_task, kind, project_id}, _from, snapshot) do
    failure_reason = "operator_task_busy: #{kind} run is already in progress"

    reply = %{
      accepted: false,
      kind: to_string(kind),
      project_id: project_id,
      status: "failed",
      run_id: "operator-#{kind}-active",
      requested_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      queued_at: nil,
      started_at: nil,
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      failure_reason: failure_reason,
      summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
    }

    {:reply, reply, snapshot}
  end

  defp fake_default_response("SymphonyLinearDiscoveryViewer", _variables) do
    %{
      "data" => %{
        "viewer" => %{"id" => "viewer-1", "name" => "Ops User", "email" => "ops@example.test"}
      }
    }
  end

  defp fake_default_response("SymphonyLinearDiscoveryTeams", _variables) do
    %{
      "data" => %{
        "teams" => %{"nodes" => [%{"id" => "team-1", "key" => "PLAT", "name" => "Platform"}]}
      }
    }
  end

  defp fake_default_response("SymphonyLinearDiscoveryTeamStates", %{"teamKey" => "PLAT"}) do
    %{
      "data" => %{
        "teams" => %{
          "nodes" => [
            %{
              "id" => "team-1",
              "key" => "PLAT",
              "states" => %{
                "nodes" => [
                  %{"id" => "state-ready", "name" => "Ready", "type" => "unstarted"},
                  %{"id" => "state-progress", "name" => "In Progress", "type" => "started"},
                  %{"id" => "state-review", "name" => "Ready to Merge", "type" => "started"},
                  %{"id" => "state-blocked", "name" => "Blocked", "type" => "started"},
                  %{"id" => "state-done", "name" => "Done", "type" => "completed"}
                ]
              }
            }
          ]
        }
      }
    }
  end

  defp fake_default_response("SymphonyLinearDiscoveryTeamStates", _variables) do
    %{"data" => %{"teams" => %{"nodes" => []}}}
  end

  defp fake_default_response("SymphonyLinearDiscoveryProjects", _variables) do
    %{
      "data" => %{
        "projects" => %{
          "nodes" => [
            %{
              "id" => "project-1",
              "name" => "Migration Project",
              "slugId" => "migration-project",
              "url" => "https://linear.app/project/migration-project",
              "teams" => %{
                "nodes" => [%{"id" => "team-1", "key" => "PLAT", "name" => "Platform"}]
              }
            }
          ]
        }
      }
    }
  end

  defp fake_default_response(_operation, _variables), do: %{}

  def start_test_endpoint(overrides \\ []) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})
  end

  def dashboard_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
      rate_limits: %{},
      polling: %{listening?: false, listening_mode: "not_listening"},
      operator_tasks: %{
        nap: %{status: "running", project_id: "fake-project-id", summary: nil},
        day_dreaming: %{status: "idle", project_id: nil, summary: nil}
      }
    }
  end

  def split_workflow_yaml do
    WorkflowFixtures.settings_workflow_yaml()
  end

  def split_profiles_yaml do
    WorkflowFixtures.settings_profiles_yaml()
  end

  def workflow_yaml_with_codex(model, effort) do
    String.replace(
      WorkflowFixtures.settings_workflow_yaml(),
      ~s(command: "codex app-server"),
      ~s(command: "codex app-server", model: "#{model}", reasoning_effort: "#{effort}")
    )
  end

  def reasoning_effort_values(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#workflow-codex-reasoning-effort option")
    |> Floki.attribute("value")
  end

  def selected_value(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#{selector} option[selected]")
    |> Floki.attribute("value")
    |> List.first()
  end

  def authority_statuses(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(".project-authority-diagnostics tbody tr td:last-child span")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  def persistence_write_count do
    Enum.count(FakePersistence.calls(), fn
      {:put_instance_workflow, _config, _prompt} -> true
      {:import_workflow, _project, _raw, _source} -> true
      {:import_package, _project, _raw, _source} -> true
      {:save_project_settings, _project_id, _attrs, _raw} -> true
      _call -> false
    end)
  end

  def project_settings_params(overrides) do
    Map.merge(
      %{
        "id" => "fake-project-id",
        "name" => "Fake Project",
        "slug" => "fake",
        "linear_project_slug" => "project",
        "repository_url" => "git@github.com:org/repo.git",
        "default_branch" => "main",
        "checkout_depth" => "1",
        "source_strategy" => "clone",
        "worktree_fetch" => "true",
        "worktree_cleanup" => "true",
        "tracker_assignee" => "",
        "active_states" => "Todo\nReady\nIn Progress",
        "terminal_states" => "Done\nCanceled\nCancelled\nDuplicate",
        "project_setup_commands" => "",
        "project_cleanup_commands" => "",
        "description" => "",
        "enabled" => "true"
      },
      overrides
    )
  end

  def restore_app_env(key, nil) do
    Application.delete_env(:symphony_elixir, key)
  end

  def restore_app_env(key, value) do
    Application.put_env(:symphony_elixir, key, value)
  end
end

defmodule Mix.Tasks.Symphony.PostgresSmokeAssertions do
  @moduledoc false

  alias Ecto.Adapters.SQL

  @spec seed_pre_repair_worker_session!(module(), String.t(), String.t()) :: term()
  def seed_pre_repair_worker_session!(repo, worker_id, session_id) do
    SQL.query!(
      repo,
      """
      INSERT INTO workers (id, name, status, labels, capabilities, inserted_at, updated_at)
      VALUES ($1::text::uuid, 'migration-smoke-worker', 'online', '{}', '{}', NOW(), NOW())
      """,
      [worker_id]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO worker_sessions (
        id, worker_id, protocol_version, total_slots, connected_at, status, inserted_at, updated_at
      )
      VALUES ($1::text::uuid, $2::text::uuid, 'worker-api-v1', 7, NOW(), 'online', NOW(), NOW())
      """,
      [session_id, worker_id]
    )
  end

  @spec verify_worker_session_compatibility!(module(), String.t(), String.t(), String.t()) :: :ok
  def verify_worker_session_compatibility!(repo, session_id, legacy_session_id, worker_id) do
    %{rows: [["YES", "1"]]} =
      SQL.query!(
        repo,
        """
        SELECT is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'worker_sessions'
          AND column_name = 'total_slots'
        """,
        []
      )

    %{rows: [[7]]} =
      SQL.query!(repo, "SELECT total_slots FROM worker_sessions WHERE id = $1::text::uuid", [session_id])

    SQL.query!(
      repo,
      """
      INSERT INTO worker_sessions (
        id, worker_id, protocol_version, connected_at, status, inserted_at, updated_at
      )
      VALUES ($1::text::uuid, $2::text::uuid, 'legacy-worker-api-v1', NOW(), 'online', NOW(), NOW())
      """,
      [legacy_session_id, worker_id]
    )

    %{rows: [[1]]} =
      SQL.query!(repo, "SELECT total_slots FROM worker_sessions WHERE id = $1::text::uuid", [legacy_session_id])

    SQL.query!(repo, "DELETE FROM workers WHERE id = $1::text::uuid", [worker_id])
    :ok
  end

  @spec assert_imported_relationships!(module(), map()) :: :ok
  def assert_imported_relationships!(repo, ids) do
    assert_core_relationships!(repo, ids)
    assert_legacy_failures!(repo)
    assert_imported_workflow!(repo, ids)
    :ok
  end

  defp assert_core_relationships!(repo, ids) do
    %{project_id: project_id, workflow_id: workflow_id, run_id: run_id, issue_id: issue_id} = ids
    %{session_id: session_id, worker_id: worker_id} = ids

    %{rows: [[^project_id, ^workflow_id]]} =
      SQL.query!(
        repo,
        """
        SELECT p.id::text, w.id::text
        FROM projects p
        JOIN workflows w ON w.project_id = p.id
        WHERE p.id = $1::text::uuid
        """,
        [project_id]
      )

    %{rows: [[^run_id, ^issue_id, "completed", nil, nil]]} =
      SQL.query!(
        repo,
        "SELECT id::text, issue_id::text, status, failure_reason, failure_evidence FROM runs WHERE id = $1::text::uuid",
        [run_id]
      )

    %{rows: [[%{"state" => "In Progress"}]]} =
      SQL.query!(repo, "SELECT snapshot FROM issues WHERE id = $1::text::uuid", [issue_id])

    %{rows: [[^session_id, ^worker_id]]} =
      SQL.query!(repo, "SELECT id::text, worker_id::text FROM worker_sessions WHERE id = $1::text::uuid", [session_id])
  end

  defp assert_legacy_failures!(repo) do
    %{rows: legacy_failures} =
      SQL.query!(
        repo,
        """
        SELECT status, failure_reason, failure_evidence
        FROM runs
        WHERE issue_identifier LIKE 'SYM-LEGACY-%'
        ORDER BY issue_identifier
        """,
        []
      )

    [
      ["failed", "unknown", %{"import" => "unclassified_legacy_reason", "legacy_failure_reason" => "opaque legacy"}],
      ["blocked", "unknown", %{"import" => "missing_failure_reason"}],
      ["cancelled", "environment_unavailable", environment_evidence]
    ] = legacy_failures

    %{
      "import" => "historical_mapping",
      "kind" => "environment_unavailable",
      "legacy_failure_reason" => "workspace erofs"
    } = environment_evidence
  end

  defp assert_imported_workflow!(repo, ids) do
    workflow_id = ids.workflow_id

    %{rows: [[yaml_config, "", raw_workflow_md]]} =
      SQL.query!(
        repo,
        "SELECT yaml_config, prompt_body, raw_workflow_md FROM workflows WHERE id = $1::text::uuid",
        [workflow_id]
      )

    ["project", "tracker"] = Enum.sort(Map.keys(yaml_config))
    false = String.contains?(raw_workflow_md, "Smoke prompt")

    %{rows: [[%{"config" => %{}, "prompt_body" => "Smoke prompt"}]]} =
      SQL.query!(repo, "SELECT value FROM app_settings WHERE key = 'instance_workflow'", [])
  end
end

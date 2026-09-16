defmodule SymphonyElixir.Repo.Migrations.ConvergeLegacyInstanceWorkflows do
  use Ecto.Migration

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Config.LegacyWorkflowConvergence

  @instance_key "instance_workflow"
  @conflict_key "legacy_instance_workflow_candidates"

  def up do
    rows = legacy_rows()
    instance_exists? = setting_exists?(@instance_key)
    {:ok, plan} = LegacyWorkflowConvergence.plan(rows, instance_exists?)

    Enum.each(plan.candidates, &rewrite_workflow/1)
    persist_setting(plan.setting)

    alter table(:projects) do
      remove(:after_create_hook)
      remove(:before_run_hook)
      remove(:after_run_hook)
      remove(:before_remove_hook)
    end
  end

  def down do
    raise "legacy instance workflow convergence is irreversible"
  end

  defp legacy_rows do
    %{rows: rows} =
      SQL.query!(
        repo(),
        """
        SELECT w.id::text,
               p.id::text,
               p.slug,
               w.yaml_config,
               w.prompt_body,
               p.after_create_hook,
               p.before_run_hook,
               p.after_run_hook,
               p.before_remove_hook
        FROM workflows AS w
        JOIN projects AS p ON p.id = w.project_id
        ORDER BY p.slug, p.id
        """,
        []
      )

    Enum.map(
      rows,
      fn [
           workflow_id,
           project_id,
           project_slug,
           yaml_config,
           prompt_body,
           after_create_hook,
           before_run_hook,
           after_run_hook,
           before_remove_hook
         ] ->
        %{
          workflow_id: workflow_id,
          project_id: project_id,
          project_slug: project_slug,
          yaml_config: yaml_config,
          prompt_body: prompt_body,
          after_create_hook: after_create_hook,
          before_run_hook: before_run_hook,
          after_run_hook: after_run_hook,
          before_remove_hook: before_remove_hook
        }
      end
    )
  end

  defp setting_exists?(key) do
    %{rows: [[exists?]]} = SQL.query!(repo(), "SELECT EXISTS(SELECT 1 FROM app_settings WHERE key = $1)", [key])
    exists?
  end

  defp rewrite_workflow(candidate) do
    SQL.query!(
      repo(),
      """
      UPDATE workflows
      SET yaml_config = $1,
          raw_workflow_md = $2,
          prompt_body = '',
          updated_at = NOW()
      WHERE id = $3::uuid
      """,
      [candidate.project_config, candidate.raw_workflow_md, candidate.workflow_id]
    )
  end

  defp persist_setting(:none), do: :ok
  defp persist_setting({:instance, value}), do: insert_setting(@instance_key, value)
  defp persist_setting({:conflict, value}), do: insert_setting(@conflict_key, value)

  defp insert_setting(key, value) do
    SQL.query!(
      repo(),
      """
      INSERT INTO app_settings (key, value, inserted_at, updated_at)
      VALUES ($1, $2, NOW(), NOW())
      """,
      [key, value]
    )
  end
end

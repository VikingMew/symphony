defmodule SymphonyElixir.Repo.Migrations.MigrateCodexCommandSelectors do
  use Ecto.Migration

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Config.CodexCommand
  alias SymphonyElixir.Workflow

  @instance_key "instance_workflow"
  @conflict_key "legacy_instance_workflow_candidates"

  def up do
    %{rows: rows} =
      SQL.query!(repo(), "SELECT id::text, yaml_config, prompt_body FROM workflows", [])

    Enum.each(rows, fn [id, config, prompt] ->
      case CodexCommand.migrate_config(config) do
        {:changed, migrated} ->
          SQL.query!(
            repo(),
            """
            UPDATE workflows
            SET yaml_config = $1,
                raw_workflow_md = $2,
                updated_at = NOW()
            WHERE id = $3::text::uuid
            """,
            [migrated, Workflow.to_markdown(migrated, prompt), id]
          )

        :unchanged ->
          :ok
      end
    end)

    migrate_setting(@instance_key, &CodexCommand.migrate_instance/1)
    migrate_setting(@conflict_key, &CodexCommand.migrate_conflict/1)
  end

  def down do
    raise "Codex command selector migration is irreversible"
  end

  defp migrate_setting(key, migrator) do
    case SQL.query!(repo(), "SELECT value FROM app_settings WHERE key = $1", [key]).rows do
      [[value]] ->
        case migrator.(value) do
          {:changed, migrated} ->
            SQL.query!(
              repo(),
              "UPDATE app_settings SET value = $1, updated_at = NOW() WHERE key = $2",
              [migrated, key]
            )

          :unchanged ->
            :ok
        end

      [] ->
        :ok
    end
  end
end

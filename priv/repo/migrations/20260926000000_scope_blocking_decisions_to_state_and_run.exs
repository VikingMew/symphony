defmodule SymphonyElixir.Repo.Migrations.ScopeBlockingDecisionsToStateAndRun do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE issues
    SET blocking_decision = jsonb_set(
      blocking_decision,
      '{origin_state}',
      to_jsonb(state),
      true
    )
    WHERE blocking_decision IS NOT NULL
      AND NOT (blocking_decision ? 'origin_state')
    """)
  end

  def down, do: :ok
end

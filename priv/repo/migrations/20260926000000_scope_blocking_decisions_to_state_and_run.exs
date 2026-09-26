defmodule SymphonyElixir.Repo.Migrations.ScopeBlockingDecisionsToStateAndRun do
  use Ecto.Migration

  def change do
    execute(
      """
      UPDATE issues
      SET blocking_decision = jsonb_set(
        blocking_decision,
        '{origin_state}',
        to_jsonb(state),
        true
      )
      WHERE blocking_decision IS NOT NULL
      """,
      """
      UPDATE issues
      SET blocking_decision = blocking_decision - 'origin_state'
      WHERE blocking_decision IS NOT NULL
      """
    )
  end
end

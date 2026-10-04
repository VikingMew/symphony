defmodule SymphonyElixir.Repo.Migrations.AddAssignmentExpiredRunFailure do
  use Ecto.Migration

  @failure_reasons ~w(
    environment_unavailable
    source_preparation_timeout
    external_dependency_timeout
    budget_exhausted
    contract_violation
    worker_process_termination
    assignment_expired
    validation_failed
    runtime_failure
    codex_upstream_capacity
    codex_turn_failed
    cancelled
    operator_stopped
    unknown
  )

  def up do
    execute("ALTER TABLE runs DROP CONSTRAINT runs_failure_reason_closed")

    execute("""
    ALTER TABLE runs
      ADD CONSTRAINT runs_failure_reason_closed
      CHECK (failure_reason IS NULL OR failure_reason IN (#{quoted_reasons()}))
    """)
  end

  defp quoted_reasons, do: Enum.map_join(@failure_reasons, ", ", &"'#{&1}'")
end

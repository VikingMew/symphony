defmodule SymphonyElixir.Worker.AssignmentManager do
  @moduledoc """
  Owns the Panel's single ephemeral worker assignment.

  Every assignment starts from a fresh tracker candidate read and a second issue read. Nothing in
  PostgreSQL is treated as queued work; runs and events are history records only.
  """

  use SymphonyElixir.Worker.AssignmentManager.Sections.Api
  use SymphonyElixir.Worker.AssignmentManager.Sections.Assignment
end

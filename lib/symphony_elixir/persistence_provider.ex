defmodule SymphonyElixir.PersistenceProvider do
  @moduledoc """
  Resolves the persistence boundary used by runtime code.

  Production defaults to `SymphonyElixir.Persistence`. Tests can replace the
  module with a fake for Web UI and workflow-source tests that do not need
  SQLite semantics.
  """

  @spec module() :: module()
  def module do
    Application.get_env(:symphony_elixir, :persistence_module, SymphonyElixir.Persistence)
  end
end

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

  @type read_error :: :repo_unavailable | {:query_failed, term()}

  @spec read((-> result)) :: result | {:error, read_error()} when result: term()
  def read(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error -> {:error, {:query_failed, error}}
  catch
    kind, reason -> {:error, {:query_failed, {kind, reason}}}
  end
end

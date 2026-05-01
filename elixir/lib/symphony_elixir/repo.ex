defmodule SymphonyElixir.Repo do
  @moduledoc """
  Ecto repository for Symphony's local SQLite persistence.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3
end

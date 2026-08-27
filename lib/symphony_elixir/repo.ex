defmodule SymphonyElixir.Repo do
  @moduledoc """
  Ecto repository for Symphony's PostgreSQL persistence.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.Postgres
end

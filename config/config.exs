import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, :start_repo, config_env() != :test

config :symphony_elixir, SymphonyElixir.Repo, pool_size: 5

config :symphony_elixir, :auth, enabled: false
config :symphony_elixir, :panel, max_concurrent_agents: 10, max_concurrent_reviews: 2

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

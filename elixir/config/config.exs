import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, SymphonyElixir.Repo,
  database: System.get_env("SYMPHONY_DATABASE_PATH") || Path.expand("../symphony.db", __DIR__),
  pool_size: String.to_integer(System.get_env("SYMPHONY_DATABASE_POOL_SIZE") || "5")

config :symphony_elixir, :auth,
  enabled: System.get_env("SYMPHONY_AUTH_ENABLED") in ["1", "true", "TRUE", "yes"],
  username: System.get_env("SYMPHONY_ADMIN_USERNAME"),
  password_hash: System.get_env("SYMPHONY_ADMIN_PASSWORD_HASH"),
  password: System.get_env("SYMPHONY_ADMIN_PASSWORD")

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

import Config

runtime_role = System.get_env("SYMPHONY_ROLE")
worker_role = runtime_role in ["worker", "host_probe"]
config :symphony_elixir, :runtime_role, if(worker_role, do: :worker, else: :panel)

positive_panel_integer = fn name, default ->
  case Integer.parse(System.get_env(name) || default) do
    {value, ""} when value > 0 -> value
    _ -> raise "#{name} must be a positive integer"
  end
end

config :symphony_elixir, :panel,
  max_concurrent_agents: positive_panel_integer.("SYMPHONY_PANEL_SLOTS", "10"),
  max_concurrent_reviews: positive_panel_integer.("SYMPHONY_PANEL_MAX_CONCURRENT_REVIEWS", "2"),
  workspace_root: System.get_env("SYMPHONY_PANEL_WORKSPACE_ROOT") || "/tmp/symphony-reviews"

if worker_role do
  required = fn name ->
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "#{name} is required for the worker role"
    end
  end

  positive_integer = fn name, default ->
    case Integer.parse(System.get_env(name) || default) do
      {value, ""} when value > 0 -> value
      _ -> raise "#{name} must be a positive integer"
    end
  end

  host_probe = runtime_role == "host_probe"

  config :symphony_elixir, :worker,
    panel_url: if(host_probe, do: System.get_env("HOST_PROBE_PANEL_ROOT") || "http://127.0.0.1:4001", else: required.("SYMPHONY_PANEL_URL")),
    registration_token: if(host_probe, do: nil, else: required.("SYMPHONY_WORKER_TOKEN")),
    worker_name: if(host_probe, do: "local-host", else: System.get_env("SYMPHONY_WORKER_NAME") || "symphony-worker"),
    workspace_root: if(host_probe, do: required.("HOST_PROBE_WORKSPACE_ROOT"), else: System.get_env("SYMPHONY_WORKER_WORKSPACE_ROOT") || "/worker/workspaces"),
    cache_root: System.get_env("SYMPHONY_WORKER_CACHE_ROOT") || "/worker/cache",
    log_root: System.get_env("SYMPHONY_WORKER_LOG_ROOT") || "/worker/logs",
    slots: positive_integer.("SYMPHONY_WORKER_SLOTS", "1"),
    retention_seconds: positive_integer.("SYMPHONY_WORKER_RETENTION_SECONDS", "86400"),
    cache_max_bytes: positive_integer.("SYMPHONY_WORKER_CACHE_MAX_BYTES", "10737418240"),
    image_reference: System.get_env("SYMPHONY_WORKER_IMAGE") || "unknown",
    source_revision: System.get_env("SYMPHONY_WORKER_SOURCE_REVISION") || "unknown",
    execution_surface: if(host_probe, do: "host_probe", else: "container_worker"),
    probe_id: if(host_probe, do: "local-host", else: nil),
    capabilities: if(host_probe, do: String.split(System.get_env("HOST_PROBE_CAPABILITIES") || "", ",", trim: true), else: []),
    token_file: if(host_probe, do: System.get_env("HOST_PROBE_TOKEN_FILE") || Path.expand("~/.symphony/probe-token"), else: nil),
    codex_launcher: if(host_probe, do: required.("HOST_PROBE_CODEX_LAUNCHER"), else: nil),
    local_deadline_seconds: 30
end

database_pool_size =
  case Integer.parse(System.get_env("SYMPHONY_DATABASE_POOL_SIZE") || "5") do
    {pool_size, ""} when pool_size > 0 -> pool_size
    _ -> raise "SYMPHONY_DATABASE_POOL_SIZE must be a positive integer"
  end

database_config = [pool_size: database_pool_size]

database_config =
  case System.get_env("DATABASE_URL") do
    url when is_binary(url) -> Keyword.put(database_config, :url, String.trim(url))
    nil -> database_config
  end

config :symphony_elixir, SymphonyElixir.Repo, database_config

config :symphony_elixir, :auth,
  enabled: System.get_env("SYMPHONY_AUTH_ENABLED") in ["1", "true", "TRUE", "yes", "YES"],
  username: System.get_env("SYMPHONY_ADMIN_USERNAME"),
  password_hash: System.get_env("SYMPHONY_ADMIN_PASSWORD_HASH"),
  password: System.get_env("SYMPHONY_ADMIN_PASSWORD")

case System.get_env("SECRET_KEY_BASE") do
  secret when is_binary(secret) and byte_size(secret) >= 64 ->
    config :symphony_elixir, SymphonyElixirWeb.Endpoint, secret_key_base: secret

  nil ->
    :ok

  _invalid ->
    raise "SECRET_KEY_BASE must contain at least 64 bytes"
end

case System.get_env("PORT") do
  nil ->
    :ok

  value ->
    case Integer.parse(value) do
      {port, ""} when port >= 0 -> config :symphony_elixir, :server_port_override, port
      _ -> raise "PORT must be a non-negative integer"
    end
end

case System.get_env("SYMPHONY_SERVER_HOST") do
  host when is_binary(host) and host != "" -> config :symphony_elixir, :server_host_override, host
  _ -> :ok
end

case System.get_env("SYMPHONY_LOGS_ROOT") do
  logs_root when is_binary(logs_root) and logs_root != "" ->
    config :symphony_elixir, :log_file, Path.join(logs_root, "symphony.log")

  _ ->
    :ok
end

if config_env() == :test do
  config :symphony_elixir, :start_http_server, false
end

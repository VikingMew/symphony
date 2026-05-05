defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router
  import SymphonyElixirWeb.AuthPlug

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :browser_auth do
    plug(:require_browser_auth)
  end

  pipeline :api do
    plug(:fetch_session)
  end

  pipeline :api_auth do
    plug(:require_api_auth)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
    delete("/logout", SessionController, :delete)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :browser_auth])

    live("/", DashboardLive, :index)
    live("/projects", AdminLive, :projects)
    live("/runs", AdminLive, :runs)
    live("/workers", AdminLive, :workers)
    live("/diagnostics/linear", LinearDiagnosticsLive, :index)
    live("/settings", AdminLive, :settings)
    live("/workflows", AdminLive, :workflows)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api)

    post("/api/worker/v1/register", WorkerApiController, :register)
    post("/api/worker/v1/tasks/claim", WorkerApiController, :claim)
    post("/api/worker/v1/heartbeat", WorkerApiController, :heartbeat)
    post("/api/worker/v1/tasks/:task_id/events", WorkerApiController, :task_event)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:api, :api_auth])

    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end

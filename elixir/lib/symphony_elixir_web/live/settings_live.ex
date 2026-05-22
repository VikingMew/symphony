defmodule SymphonyElixirWeb.SettingsLive do
  @moduledoc """
  Settings route boundary.

  The settings surface still reuses AdminLive rendering and event handlers while
  the route ownership moves out of the broad admin LiveView.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.AdminLive

  @impl true
  def mount(params, session, socket), do: AdminLive.mount(params, session, socket)

  @impl true
  def handle_params(params, uri, socket), do: AdminLive.handle_params(params, uri, socket)

  @impl true
  def handle_event(event, params, socket), do: AdminLive.handle_event(event, params, socket)

  @impl true
  def render(assigns), do: AdminLive.render(assigns)
end

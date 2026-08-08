defmodule SymphonyElixirWeb.AdminLive.Runs do
  @moduledoc false

  use Phoenix.Component

  alias SymphonyElixir.PersistenceProvider
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  @runs_page_size 25

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <h1 class="section-title">Runs</h1>
        <SymphonyElixirWeb.Layouts.project_switcher projects={@projects} current={@event_filters.project_id} base_path="/runs" />
      </div>
      <%= if @runs == [] do %>
        <p class="empty-state">No persisted runs yet.</p>
      <% else %>
        <table class="data-table">
          <thead><tr><th>Run</th><th>Kind</th><th>Status</th><th>Attempt</th><th>Started</th><th>Finished</th></tr></thead>
          <tbody>
            <tr :for={run <- @runs}>
              <td class="issue-id">
                <a class="issue-link" href={"/runs/#{run.id}"}><%= run_label(run) %></a>
                <a :if={Map.get(run, :issue_identifier)} class="issue-link" href={"/issues/#{run.issue_identifier}"}>Issue</a>
              </td>
              <td><%= Map.get(run, :kind) || "issue" %></td>
              <td><%= Map.get(run, :status) %></td>
              <td><%= Map.get(run, :attempt) || 0 %></td>
              <td class="mono"><%= ObservabilityPresenter.fmt_dt(Map.get(run, :started_at)) %></td>
              <td class="mono"><%= ObservabilityPresenter.fmt_dt(Map.get(run, :finished_at)) %></td>
            </tr>
          </tbody>
        </table>
        <div class="form-actions">
          <button :if={@runs_has_more} type="button" class="subtle-button" phx-click="load_more_runs">Load more runs</button>
          <span :if={!@runs_has_more} class="muted">All matching runs are loaded.</span>
        </div>
      <% end %>
    </section>
    """
  end

  @spec assign_page(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def assign_page(socket, opts) do
    reset = Keyword.get(opts, :reset, true)
    cursor = if reset, do: nil, else: Map.get(socket.assigns, :runs_next_cursor)

    page =
      persistence().list_runs_page(
        page_size: @runs_page_size,
        cursor: cursor,
        project_id: project_filter(socket)
      )

    existing = if reset, do: [], else: Map.get(socket.assigns, :runs, [])

    socket
    |> assign(:runs, existing ++ page.entries)
    |> assign(:runs_next_cursor, page.next_cursor)
    |> assign(:runs_has_more, page.has_more?)
  end

  defp project_filter(%{assigns: %{route_params: params}}) do
    SymphonyElixir.Text.blank_as_nil(Map.get(params, "project", ""))
  end

  defp run_label(run) do
    Map.get(run, :label) || Map.get(run, :issue_identifier) || Map.get(run, :id) || "n/a"
  end

  defp persistence, do: PersistenceProvider.module()
end

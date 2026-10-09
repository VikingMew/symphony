defmodule SymphonyElixirWeb.DashboardBlockingDecisionControl do
  @moduledoc false

  alias Phoenix.LiveView
  alias SymphonyElixirWeb.{Presenter, WebRuntime}

  @spec remove_persistent_block(String.t(), map(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def remove_persistent_block(
        "clear_blocking_decision",
        %{"issue_identifier" => issue_identifier},
        socket
      ) do
    result =
      SymphonyElixir.Orchestrator.clear_blocking_decision(
        issue_identifier,
        WebRuntime.orchestrator()
      )

    socket =
      socket
      |> put_result_flash(issue_identifier, result)
      |> Phoenix.Component.assign(
        :payload,
        Presenter.state_payload(WebRuntime.orchestrator(), WebRuntime.snapshot_timeout_ms())
      )
      |> Phoenix.Component.assign(:now, DateTime.utc_now())

    {:noreply, socket}
  end

  defp put_result_flash(socket, issue_identifier, result) do
    {level, message} =
      case result do
        %{status: "cleared"} ->
          {:info, "Cleared blocking decision for #{issue_identifier}."}

        %{status: "already_cleared"} ->
          {:info, "Blocking decision for #{issue_identifier} was already cleared."}

        :unavailable ->
          {:error, "Could not clear #{issue_identifier}: orchestrator unavailable."}

        {:error, reason} ->
          {:error, "Could not clear #{issue_identifier}: #{inspect(reason)}"}
      end

    LiveView.put_flash(socket, level, message)
  end
end

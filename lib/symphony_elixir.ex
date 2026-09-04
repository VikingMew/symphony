defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    case Application.get_env(:symphony_elixir, :runtime_role, :panel) do
      :worker -> SymphonyElixir.Worker.Application.start_link()
      :panel -> start_panel()
    end
  end

  defp start_panel do
    with :ok <- validate_database_config(),
         :ok <- SymphonyElixir.LogFile.configure() do
      start_supervisor()
    end
  end

  defp start_supervisor do
    children =
      [
        repo_child(),
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.Linear.Health,
        SymphonyElixir.WorkflowStore,
        SymphonyElixir.Orchestrator,
        review_queue_child(),
        http_server_child(),
        SymphonyElixir.StatusDashboard
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp repo_child do
    if Application.get_env(:symphony_elixir, :start_repo, true) do
      SymphonyElixir.Repo
    end
  end

  defp review_queue_child do
    if Application.get_env(:symphony_elixir, :start_repo, true) do
      SymphonyElixir.PRReview.Queue
    end
  end

  defp http_server_child do
    if Application.get_env(:symphony_elixir, :start_http_server, true) do
      SymphonyElixir.HttpServer
    end
  end

  defp validate_database_config do
    if Application.get_env(:symphony_elixir, :start_repo, true) do
      SymphonyElixir.DatabaseSetup.validate_config()
    else
      :ok
    end
  end
end

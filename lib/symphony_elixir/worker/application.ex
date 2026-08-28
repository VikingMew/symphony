defmodule SymphonyElixir.Worker.Application do
  @moduledoc false

  @spec start_link() :: Supervisor.on_start()
  def start_link do
    config = SymphonyElixir.Worker.Config.load!()
    :ok = SymphonyElixir.Worker.Paths.prepare_roots(config)

    Supervisor.start_link(
      [{Task.Supervisor, name: SymphonyElixir.Worker.TaskSupervisor}, {SymphonyElixir.Worker.Runtime, config}],
      strategy: :one_for_one,
      name: SymphonyElixir.Worker.Supervisor
    )
  end
end

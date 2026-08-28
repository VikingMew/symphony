defmodule SymphonyElixir.Worker.Application do
  @moduledoc false

  alias SymphonyElixir.Worker.{Config, Paths, Runtime}
  alias SymphonyElixir.Worker.Supervisor, as: WorkerSupervisor
  alias SymphonyElixir.Worker.TaskSupervisor, as: WorkerTaskSupervisor
  alias Task.Supervisor, as: TaskSupervisor

  @spec start_link() :: Supervisor.on_start()
  def start_link do
    config = Config.load!()
    :ok = Paths.prepare_roots(config)

    Supervisor.start_link(
      [{TaskSupervisor, name: WorkerTaskSupervisor}, {Runtime, config}],
      strategy: :one_for_one,
      name: WorkerSupervisor
    )
  end
end

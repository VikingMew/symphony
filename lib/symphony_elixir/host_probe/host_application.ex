defmodule SymphonyElixir.HostProbe.HostApplication do
  @moduledoc false

  alias SymphonyElixir.HostProbe.{HostConfig, HostRuntime}

  @spec start_host_probe_link() :: Supervisor.on_start()
  def start_host_probe_link do
    config = HostConfig.load_host_config!()

    Supervisor.start_link(
      [
        {Task.Supervisor, name: SymphonyElixir.HostProbe.TaskSupervisor},
        %{
          id: HostRuntime,
          start: {HostRuntime, :start_host_runtime_link, [config]}
        }
      ],
      strategy: :one_for_one,
      name: SymphonyElixir.HostProbe.Supervisor
    )
  end
end

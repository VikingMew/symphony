defmodule SymphonyElixir.Worker.Command do
  @moduledoc false

  @spec run(map(), Path.t()) :: map()
  def run(%{command: command, timeout_seconds: timeout}, cwd) do
    started = System.monotonic_time(:millisecond)

    result =
      case System.find_executable("bash") do
        nil -> %{status: :toolchain_unavailable, exit_code: nil, detail: "bash unavailable"}
        bash -> run_port(bash, command, cwd, timeout * 1_000)
      end

    Map.put(result, :duration_ms, System.monotonic_time(:millisecond) - started)
  end

  defp run_port(bash, command, cwd, timeout) do
    port = Port.open({:spawn_executable, bash}, [:binary, :exit_status, :stderr_to_stdout, {:args, ["-lc", command]}, {:cd, cwd}])
    collect(port, timeout, <<>>)
  end

  defp collect(port, timeout, output) do
    receive do
      {^port, {:data, data}} -> collect(port, timeout, bounded(output <> data))
      {^port, {:exit_status, 0}} -> %{status: :passed, exit_code: 0, detail: bounded(output)}
      {^port, {:exit_status, code}} -> %{status: :failed, exit_code: code, detail: bounded(output)}
    after
      timeout ->
        Port.close(port)
        %{status: :timed_out, exit_code: nil, detail: bounded(output)}
    end
  end

  defp bounded(value), do: binary_part(value, 0, min(byte_size(value), 4_096))
end

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
    {executable, args} =
      case System.find_executable("setsid") do
        nil -> {bash, ["-lc", command]}
        setsid -> {setsid, [bash, "-lc", command]}
      end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, cwd}
      ])

    collect(port, System.monotonic_time(:millisecond) + timeout, <<>>)
  end

  defp collect(port, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, deadline, bounded(output <> data))
      {^port, {:exit_status, 0}} -> %{status: :passed, exit_code: 0, detail: bounded(output)}
      {^port, {:exit_status, code}} when code in [126, 127] ->
        %{status: :toolchain_unavailable, exit_code: code, detail: bounded(output)}

      {^port, {:exit_status, code}} -> %{status: :failed, exit_code: code, detail: bounded(output)}
      {:EXIT, from, :shutdown} when is_pid(from) ->
        terminate_group(port)
        %{status: :cancelled, exit_code: nil, detail: bounded(output)}
    after
      remaining ->
        terminate_group(port)
        %{status: :timed_out, exit_code: nil, detail: bounded(output)}
    end
  end

  defp terminate_group(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        signal_group(pid, "-TERM")

        receive do
          {^port, {:exit_status, _code}} -> :ok
        after
          1_000 ->
            signal_group(pid, "-KILL")
            safe_close(port)
        end

      nil ->
        safe_close(port)
    end
  end

  defp signal_group(pid, signal) do
    case System.find_executable("kill") do
      nil -> :ok
      executable -> System.cmd(executable, [signal, "--", "-#{pid}"], stderr_to_stdout: true)
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp bounded(value), do: SymphonyElixir.Redaction.bounded(value, 4_096)
end

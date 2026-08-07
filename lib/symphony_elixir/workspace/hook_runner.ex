defmodule SymphonyElixir.Workspace.HookRunner do
  @moduledoc """
  Executes local workspace hooks and normalizes hook output/timeout results.
  """

  @recent_output_bytes 4_096

  @spec run_local(String.t(), Path.t(), pos_integer(), (binary(), binary() -> term())) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, {:workspace_hook_timeout, String.t(), pos_integer(), map()}}
  def run_local(command, workspace, timeout_ms, on_output)
      when is_binary(command) and is_binary(workspace) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_function(on_output, 2) do
    started_at = System.monotonic_time(:millisecond)
    port = open_port(command, workspace)

    receive_port(port, timeout_ms, started_at, "", on_output)
  end

  @spec sanitize_output(term(), pos_integer()) :: binary()
  def sanitize_output(output, max_bytes \\ 2_048) do
    SymphonyElixir.Redaction.bounded(output, max_bytes)
  end

  @spec append_recent_output(binary(), iodata()) :: binary()
  def append_recent_output(current, chunk) when is_binary(current) do
    output = current <> IO.iodata_to_binary(chunk)

    case byte_size(output) <= @recent_output_bytes do
      true -> output
      false -> binary_part(output, byte_size(output) - @recent_output_bytes, @recent_output_bytes)
    end
  end

  defp open_port(command, workspace) do
    sh = System.find_executable("sh") || "/bin/sh"

    Port.open({:spawn_executable, sh}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["-lc", command]},
      {:cd, workspace},
      {:env, [{~c"GIT_TERMINAL_PROMPT", ~c"0"}]}
    ])
  end

  defp receive_port(port, timeout_ms, started_at, recent_output, on_output) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    remaining_ms = max(timeout_ms - elapsed_ms, 0)

    receive do
      {^port, {:data, chunk}} ->
        sanitized_chunk = sanitize_output(chunk, @recent_output_bytes)
        recent_output = append_recent_output(recent_output, sanitized_chunk)
        on_output.(chunk, recent_output)
        receive_port(port, timeout_ms, started_at, recent_output, on_output)

      {^port, {:exit_status, status}} ->
        {:ok, {recent_output, status}}
    after
      remaining_ms ->
        close_port(port)

        details = %{
          elapsed_ms: System.monotonic_time(:millisecond) - started_at,
          recent_output: recent_output
        }

        {:error, {:workspace_hook_timeout, "local_command", timeout_ms, details}}
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _reason -> :ok
  end
end

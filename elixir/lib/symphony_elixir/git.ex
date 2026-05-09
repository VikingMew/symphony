defmodule SymphonyElixir.Git do
  @moduledoc """
  Small git command boundary used by backend-owned workflow actions.
  """

  @recent_output_bytes 4_096

  @type command_result :: {:ok, String.t()} | {:error, term()}

  @spec checkout_work_branch(Path.t(), String.t(), keyword()) :: command_result()
  def checkout_work_branch(workspace, branch, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")

    case remote_branch_exists?(workspace, branch, opts) do
      {:ok, true} ->
        with {:ok, _output} <- run(workspace, ["fetch", remote, branch], opts) do
          run(workspace, ["checkout", "-B", branch, "#{remote}/#{branch}"], opts)
        end

      {:ok, false} ->
        run(workspace, ["checkout", "-B", branch], opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remote_branch_exists?(Path.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def remote_branch_exists?(workspace, branch, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")

    case run(workspace, ["ls-remote", "--heads", remote, branch], opts) do
      {:ok, output} -> {:ok, String.trim(output) != ""}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec merge_branch(Path.t(), String.t(), keyword()) :: command_result()
  def merge_branch(workspace, branch, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")
    base_branch = Keyword.fetch!(opts, :base_branch)

    with {:ok, true} <- remote_branch_exists?(workspace, branch, opts),
         {:ok, _output} <- run(workspace, ["fetch", remote, branch], opts),
         {:ok, _output} <- run(workspace, ["checkout", base_branch], opts),
         {:ok, output} <- run(workspace, ["merge", "--no-edit", "#{remote}/#{branch}"], opts),
         {:ok, _push_output} <- maybe_push(workspace, base_branch, opts) do
      {:ok, output}
    else
      {:ok, false} -> {:error, {:remote_branch_not_found, branch}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run(Path.t(), [String.t()], keyword()) :: command_result()
  def run(workspace, args, opts \\ []) when is_binary(workspace) and is_list(args) do
    runner = Keyword.get(opts, :runner, &run_git_command/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)

    case runner.(workspace, args, timeout_ms) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, sanitize_reason(reason)}
      {output, 0} -> {:ok, to_string(output)}
      {output, status} -> {:error, {:git_command_failed, args, status, sanitize_output(output)}}
      other -> {:error, {:unexpected_git_result, other}}
    end
  end

  defp maybe_push(workspace, base_branch, opts) do
    if Keyword.get(opts, :push, false) do
      remote = Keyword.get(opts, :remote, "origin")
      run(workspace, ["push", remote, base_branch], opts)
    else
      {:ok, ""}
    end
  end

  defp run_git_command(workspace, args, timeout_ms) do
    executable = System.find_executable("git") || "git"
    started_at = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, workspace},
        {:env, [{~c"GIT_TERMINAL_PROMPT", ~c"0"}]}
      ])

    receive_git_port(port, args, timeout_ms, started_at, "")
  end

  defp receive_git_port(port, args, timeout_ms, started_at, recent_output) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    remaining_ms = max(timeout_ms - elapsed_ms, 0)

    receive do
      {^port, {:data, chunk}} ->
        receive_git_port(port, args, timeout_ms, started_at, append_recent_output(recent_output, chunk))

      {^port, {:exit_status, 0}} ->
        {:ok, recent_output}

      {^port, {:exit_status, status}} ->
        {:error, {:git_command_failed, args, status, sanitize_output(recent_output)}}
    after
      remaining_ms ->
        close_port(port)
        {:error, {:git_command_timeout, args, timeout_ms, sanitize_output(recent_output)}}
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _reason -> :ok
  end

  defp append_recent_output(current, chunk) do
    output = current <> IO.iodata_to_binary(chunk)

    if byte_size(output) <= @recent_output_bytes do
      output
    else
      binary_part(output, byte_size(output) - @recent_output_bytes, @recent_output_bytes)
    end
  end

  defp sanitize_reason({kind, args, status, output}) when kind in [:git_command_failed, :git_command_timeout] do
    {kind, args, status, sanitize_output(output)}
  end

  defp sanitize_reason(reason), do: reason

  defp sanitize_output(output) do
    output
    |> to_string()
    |> String.replace(~r/(?i)(authorization\s*[:=]\s*)(bearer|basic)?\s*[^\s,;]+/, "\\1[REDACTED]")
    |> String.replace(~r/(?i)((?:api[_-]?key|token|secret)\s*[:=]\s*)[^\s,;]+/, "\\1[REDACTED]")
  end
end

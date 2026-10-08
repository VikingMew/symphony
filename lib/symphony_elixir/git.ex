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
    SymphonyElixir.Redaction.credentials(output)
  end

  @spec prepare_work_branch(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{base_sha: String.t(), task_sha: String.t(), prepared_head: String.t()}} | {:error, term()}
  def prepare_work_branch(workspace, default_branch, task_branch, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")
    default_ref = "refs/remotes/#{remote}/#{default_branch}"
    task_ref = "refs/remotes/#{remote}/#{task_branch}"

    with {:ok, _output} <-
           run(
             workspace,
             ["fetch", "--no-tags", remote, "+refs/heads/#{default_branch}:#{default_ref}"],
             opts
           ),
         {:ok, base_sha} <- resolve_git_commit(workspace, default_ref, opts),
         {:ok, task_sha} <- checkout_task_branch(workspace, remote, task_branch, task_ref, base_sha, opts),
         :ok <- merge_base(workspace, base_sha, task_sha, opts),
         {:ok, prepared_head} <- resolve_git_commit(workspace, "HEAD", opts),
         :ok <- verify_work_branch(workspace, default_ref, base_sha, task_sha, opts) do
      {:ok, %{base_sha: base_sha, task_sha: task_sha, prepared_head: prepared_head}}
    end
  end

  defp checkout_task_branch(workspace, remote, branch, task_ref, base_sha, opts) do
    case remote_branch_exists?(workspace, branch, opts) do
      {:ok, true} ->
        with {:ok, _output} <-
               run(
                 workspace,
                 ["fetch", "--no-tags", remote, "+refs/heads/#{branch}:#{task_ref}"],
                 opts
               ),
             {:ok, _output} <- run(workspace, ["checkout", "-B", branch, task_ref], opts),
             do: resolve_git_commit(workspace, "HEAD", opts)

      {:ok, false} ->
        with {:ok, _output} <- run(workspace, ["checkout", "-B", branch, base_sha], opts),
             do: {:ok, base_sha}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_base(workspace, base_sha, task_sha, opts) do
    case run(workspace, ["merge-base", "--is-ancestor", base_sha, task_sha], opts) do
      {:ok, _output} ->
        :ok

      {:error, {:git_command_failed, _args, 1, _output}} ->
        with {:ok, _output} <- run(workspace, ["merge-base", base_sha, task_sha], opts),
             {:ok, _output} <-
               run(
                 workspace,
                 [
                   "-c",
                   "user.name=Symphony",
                   "-c",
                   "user.email=symphony@localhost",
                   "merge",
                   "--no-edit",
                   base_sha
                 ],
                 opts
               ) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_work_branch(workspace, default_ref, base_sha, task_sha, opts) do
    with {:ok, _output} <- run(workspace, ["merge-base", "--is-ancestor", task_sha, "HEAD"], opts),
         {:ok, _output} <- run(workspace, ["merge-base", "--is-ancestor", base_sha, "HEAD"], opts),
         {:ok, merge_base} <- run(workspace, ["merge-base", default_ref, "HEAD"], opts),
         true <- String.trim(merge_base) == base_sha do
      :ok
    else
      false -> {:error, {:git_postcondition_failed, :default_merge_base, base_sha}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_git_commit(workspace, ref, opts) do
    case run(workspace, ["rev-parse", "--verify", "#{ref}^{commit}"], opts) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule SymphonyElixir.Workspace.Remote do
  @moduledoc """
  Remote workspace command construction and SSH execution.
  """

  alias SymphonyElixir.{Shell, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @spec ensure_workspace(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t(), boolean()} | {:error, term()}
  def ensure_workspace(worker_host, workspace, timeout_ms)
      when is_binary(worker_host) and is_binary(workspace) do
    script =
      [
        "set -eu",
        shell_assign("workspace", workspace),
        "rm -rf \"$workspace\"",
        "mkdir -p \"$workspace\"",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' '1' \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_command(worker_host, script, timeout_ms) do
      {:ok, {output, 0}} ->
        parse_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remove_workspace(String.t(), String.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_workspace(worker_host, workspace, timeout_ms)
      when is_binary(worker_host) and is_binary(workspace) do
    script =
      [
        shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_command(worker_host, script, timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec hook_script(String.t(), String.t()) :: String.t()
  def hook_script(workspace, command) when is_binary(workspace) and is_binary(command) do
    "cd #{Shell.escape(workspace)} && #{command}"
  end

  @spec before_remove_script(String.t(), String.t()) :: String.t()
  def before_remove_script(workspace, command) when is_binary(workspace) and is_binary(command) do
    [
      shell_assign("workspace", workspace),
      "if [ -d \"$workspace\" ]; then",
      "  cd \"$workspace\"",
      "  #{command}",
      "fi"
    ]
    |> Enum.join("\n")
  end

  @spec shell_assign(String.t(), String.t()) :: String.t()
  def shell_assign(variable_name, raw_path)
      when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{Shell.escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  @spec parse_workspace_output(iodata()) :: {:ok, String.t(), boolean()} | {:error, term()}
  def parse_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  @spec run_command(String.t(), String.t(), pos_integer()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, term()}
  def run_command(worker_host, script, timeout_ms)
      when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end
end

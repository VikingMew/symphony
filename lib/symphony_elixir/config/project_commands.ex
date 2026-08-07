defmodule SymphonyElixir.Config.ProjectCommands do
  @moduledoc """
  Generated project bootstrap and cleanup command construction.
  """

  alias SymphonyElixir.Config.Schema

  @spec generated_project_bootstrap_commands(term()) :: String.t() | nil
  def generated_project_bootstrap_commands(%Schema.Project{} = project) do
    commands =
      []
      |> maybe_append_source_command(project)
      |> Kernel.++(project.setup_commands || [])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if commands == [], do: nil, else: Enum.join(commands, "\n")
  end

  def generated_project_bootstrap_commands(_project), do: nil

  @spec project_setup_commands(term()) :: String.t() | nil
  def project_setup_commands(%Schema.Project{} = project) do
    commands =
      project.setup_commands
      |> List.wrap()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if commands == [], do: nil, else: Enum.join(commands, "\n")
  end

  def project_setup_commands(_project), do: nil

  @spec generated_before_remove_hook(term()) :: String.t() | nil
  def generated_before_remove_hook(%Schema.Project{} = project) do
    commands =
      project.cleanup_commands
      |> List.wrap()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if commands == [], do: nil, else: Enum.join(commands, "\n")
  end

  def generated_before_remove_hook(_project), do: nil

  defp maybe_append_source_command(commands, %Schema.Project{source_strategy: "worktree"}), do: commands

  defp maybe_append_source_command(commands, %Schema.Project{repository_url: repository_url})
       when not is_binary(repository_url) or repository_url == "" do
    commands
  end

  defp maybe_append_source_command(commands, %Schema.Project{} = project) do
    clone_parts =
      ["GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=", "SSH_ASKPASS="]
      |> maybe_append_git_ssh_command(project.repository_url)
      |> Kernel.++([
        "git",
        "-c",
        "credential.helper=",
        "-c",
        "core.askPass=",
        "-c",
        "http.lowSpeedLimit=1",
        "-c",
        "http.lowSpeedTime=30",
        "clone",
        "--progress"
      ])
      |> maybe_append_clone_depth(project.checkout_depth)
      |> maybe_append_clone_branch(project.default_branch)
      |> Kernel.++([SymphonyElixir.Shell.escape(project.repository_url), "."])

    commands ++ [Enum.join(clone_parts, " ")]
  end

  defp maybe_append_git_ssh_command(parts, repository_url) when is_binary(repository_url) do
    if ssh_repository_url?(repository_url) do
      parts ++
        [
          "GIT_SSH_COMMAND=#{SymphonyElixir.Shell.escape("ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new")}"
        ]
    else
      parts
    end
  end

  defp maybe_append_git_ssh_command(parts, _repository_url), do: parts

  defp ssh_repository_url?(repository_url) do
    String.starts_with?(repository_url, "git@") or String.starts_with?(repository_url, "ssh://")
  end

  defp maybe_append_clone_depth(parts, depth) when is_integer(depth) and depth > 0 do
    parts ++ ["--depth", Integer.to_string(depth)]
  end

  defp maybe_append_clone_depth(parts, _depth), do: parts

  defp maybe_append_clone_branch(parts, branch) when is_binary(branch) and branch != "" do
    parts ++ ["--branch", SymphonyElixir.Shell.escape(branch)]
  end

  defp maybe_append_clone_branch(parts, _branch), do: parts
end

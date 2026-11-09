defmodule SymphonyElixir.HostProbe.HostWorkspace do
  @moduledoc "Resolves and verifies the operator-prepared issue workspace."

  alias SymphonyElixir.PathSafety

  @type workspace_evidence :: %{kind: String.t(), stage: String.t()}

  @spec resolve_host_workspace(Path.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, workspace_evidence()}
  def resolve_host_workspace(root, issue_identifier, opts \\ []) when is_binary(root) and is_binary(issue_identifier) do
    canonicalize = Keyword.get(opts, :canonicalize, &PathSafety.canonicalize/1)
    stat = Keyword.get(opts, :stat, &File.stat/1)
    list = Keyword.get(opts, :list, &File.ls/1)
    write_probe = Keyword.get(opts, :write_probe, &probe_host_workspace_write/1)
    expanded_root = Path.expand(root)
    expanded_workspace = Path.expand(Path.join(root, issue_identifier))

    with :ok <- normalize_host_identifier(issue_identifier),
         {:ok, canonical_root} <- canonicalize.(expanded_root),
         {:ok, canonical_workspace} <- canonicalize.(expanded_workspace),
         :ok <- verify_host_containment(canonical_workspace, expanded_workspace, expanded_root, canonical_root),
         {:ok, %File.Stat{type: :directory}} <- stat.(canonical_workspace),
         {:ok, _entries} <- list.(canonical_workspace),
         :ok <- write_probe.(canonical_workspace) do
      {:ok, canonical_workspace}
    else
      {:error, %{kind: _kind} = evidence} -> {:error, evidence}
      {:error, :enoent} -> host_workspace_unavailable("workspace_missing")
      {:ok, %File.Stat{}} -> host_workspace_unavailable("workspace_not_directory")
      {:error, :eacces} -> host_workspace_unavailable("workspace_unreadable")
      {:error, :erofs} -> host_workspace_unavailable("workspace_not_writable")
      {:error, _reason} -> host_workspace_unavailable("workspace_unavailable")
    end
  end

  defp normalize_host_identifier(identifier) do
    if identifier != "" and Path.basename(identifier) == identifier and identifier not in [".", ".."],
      do: :ok,
      else: host_workspace_unavailable("workspace_escape")
  end

  defp verify_host_containment(canonical_workspace, expanded_workspace, expanded_root, canonical_root) do
    case PathSafety.classify_strict_descendant(
           canonical_workspace,
           expanded_workspace,
           [{expanded_root, canonical_root}]
         ) do
      {:inside, ^canonical_root} -> :ok
      _other -> host_workspace_unavailable("workspace_escape")
    end
  end

  defp probe_host_workspace_write(workspace) do
    name = ".symphony-write-probe-#{System.unique_integer([:positive])}"
    path = Path.join(workspace, name)

    case File.open(path, [:write, :exclusive]) do
      {:ok, device} ->
        File.close(device)
        File.rm(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp host_workspace_unavailable(kind), do: {:error, %{kind: kind, stage: "workspace_preflight"}}
end

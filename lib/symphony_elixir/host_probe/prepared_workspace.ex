defmodule SymphonyElixir.HostProbe.PreparedWorkspace do
  @moduledoc "Resolves and verifies an operator-prepared issue workspace."

  alias SymphonyElixir.PathSafety

  @spec locate(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, :workspace_unavailable, map()}
  def locate(root, issue_identifier) when is_binary(root) and is_binary(issue_identifier) do
    workspace_key = safe_workspace_key(issue_identifier)
    expanded_root = Path.expand(root)
    expected = Path.join(expanded_root, workspace_key)

    with {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(expected),
         {:inside, ^canonical_root} <-
           PathSafety.classify_strict_descendant(canonical_workspace, expected, [{expanded_root, canonical_root}]),
         true <- File.dir?(canonical_workspace),
         :ok <- writable(canonical_workspace) do
      {:ok, canonical_workspace}
    else
      {:error, {:path_canonicalize_failed, _path, :enoent}} -> workspace_unavailable(workspace_key, "missing")
      {:error, {:path_canonicalize_failed, _path, _reason}} -> workspace_unavailable(workspace_key, "unreadable")
      {:symlink_escape, _root} -> workspace_unavailable(workspace_key, "escaping")
      :outside -> workspace_unavailable(workspace_key, "escaping")
      {:exact_root, _root} -> workspace_unavailable(workspace_key, "escaping")
      false -> workspace_unavailable(workspace_key, "missing")
      {:error, :unwritable} -> workspace_unavailable(workspace_key, "unwritable")
    end
  end

  defp writable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o200) != 0 -> :ok
      _ -> {:error, :unwritable}
    end
  end

  defp workspace_unavailable(workspace_key, reason) do
    {:error, :workspace_unavailable, %{kind: "host_workspace_unavailable", reason: reason, workspace_key: workspace_key}}
  end

  defp safe_workspace_key(identifier) do
    identifier
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.trim("-")
  end
end

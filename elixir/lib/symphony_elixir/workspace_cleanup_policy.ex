defmodule SymphonyElixir.WorkspaceCleanupPolicy do
  @moduledoc """
  Shared guardrail for destructive workspace cleanup operations.

  Local workspace cleanup and `git worktree remove` both delete paths selected
  from runtime settings. This module keeps the allow/deny rules in one place so
  callers cannot accidentally diverge.
  """

  alias SymphonyElixir.PathSafety

  @type reason ::
          :empty_path
          | :invalid_path
          | {:path_canonicalize_failed, Path.t(), term()}
          | {:cleanup_path_outside_roots, Path.t(), [Path.t()]}
          | {:cleanup_path_equals_root, Path.t()}
          | {:cleanup_path_contains_protected_path, Path.t(), Path.t()}
          | {:cleanup_path_equals_protected_path, Path.t()}

  @spec validate_local_delete(Path.t(), keyword()) :: :ok | {:error, reason()}
  def validate_local_delete(path, opts) when is_binary(path) do
    roots = Keyword.fetch!(opts, :roots)
    protected_paths = Keyword.get(opts, :protected_paths, [])

    with {:ok, delete_path} <- canonical(path),
         {:ok, canonical_roots} <- canonical_all(roots),
         {:ok, canonical_protected_paths} <- canonical_all(protected_paths),
         :ok <- reject_root_delete(delete_path, canonical_roots),
         :ok <- require_inside_root(delete_path, canonical_roots) do
      reject_protected_delete(delete_path, canonical_protected_paths)
    end
  end

  def validate_local_delete(_path, _opts), do: {:error, :invalid_path}

  @spec validate_remote_delete(Path.t(), Path.t()) :: :ok | {:error, reason()}
  def validate_remote_delete(path, root) when is_binary(path) and is_binary(root) do
    delete_path = Path.expand(path)
    root_path = Path.expand(root)

    cond do
      String.trim(path) == "" or String.trim(root) == "" ->
        {:error, :empty_path}

      String.contains?(path, ["\n", "\r", <<0>>]) ->
        {:error, :invalid_path}

      delete_path == root_path ->
        {:error, {:cleanup_path_equals_root, delete_path}}

      inside?(delete_path, root_path) ->
        :ok

      true ->
        {:error, {:cleanup_path_outside_roots, delete_path, [root_path]}}
    end
  end

  def validate_remote_delete(_path, _root), do: {:error, :invalid_path}

  defp canonical(path) when is_binary(path) do
    path
    |> Path.expand()
    |> PathSafety.canonicalize()
  end

  defp canonical(path), do: {:error, {:path_canonicalize_failed, inspect(path), :invalid_path}}

  defp canonical_all(paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case canonical(path) do
        {:ok, canonical_path} -> {:cont, {:ok, [canonical_path | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reject_root_delete(delete_path, roots) do
    if delete_path in roots do
      {:error, {:cleanup_path_equals_root, delete_path}}
    else
      :ok
    end
  end

  defp require_inside_root(delete_path, roots) do
    if Enum.any?(roots, &inside?(delete_path, &1)) do
      :ok
    else
      {:error, {:cleanup_path_outside_roots, delete_path, roots}}
    end
  end

  defp reject_protected_delete(_delete_path, []), do: :ok

  defp reject_protected_delete(delete_path, protected_paths) do
    Enum.find_value(protected_paths, :ok, fn protected_path ->
      cond do
        delete_path == protected_path ->
          {:error, {:cleanup_path_equals_protected_path, delete_path}}

        inside?(protected_path, delete_path) ->
          {:error, {:cleanup_path_contains_protected_path, delete_path, protected_path}}

        true ->
          false
      end
    end)
  end

  defp inside?(path, root) do
    String.starts_with?(path <> "/", root <> "/")
  end
end

defmodule SymphonyElixir.WorkspacePreflight do
  @moduledoc """
  Validates the Panel workspace root before Settings persistence or listening.
  """

  alias SymphonyElixir.WorkspaceDiskGuard

  @type error_kind ::
          :not_creatable
          | :not_writable
          | :unreadable
          | :low_disk_space
          | :disk_space_unavailable
  @type rejection :: %{kind: error_kind(), path: String.t(), reason: term()}

  @spec check(:settings_save | :pre_listen, keyword()) :: :ok | {:error, rejection()}
  def check(type, opts \\ [])

  def check(:settings_save, opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()
    check_root(root, opts)
  end

  def check(:pre_listen, opts) do
    settings = Keyword.fetch!(opts, :settings)
    root = settings |> Map.fetch!(:workspace) |> Map.fetch!(:root) |> Path.expand()

    with :ok <- check_root(root, opts) do
      check_disk_space(settings, opts)
    end
  end

  defp check_root(root, opts) do
    path_info_fun = Keyword.get(opts, :path_info_fun, &File.stat/1)
    write_probe_fun = Keyword.get(opts, :write_probe_fun, &write_probe/1)

    case path_info_fun.(root) do
      {:ok, %File.Stat{type: :directory}} -> probe(root, :not_writable, write_probe_fun)
      {:ok, %File.Stat{type: type}} -> rejection(:not_creatable, root, {:not_directory, type})
      {:error, :enoent} -> check_missing_root(root, path_info_fun, write_probe_fun)
      {:error, :enotdir} -> rejection(:not_creatable, root, :enotdir)
      {:error, reason} -> rejection(:unreadable, root, reason)
    end
  end

  defp check_missing_root(root, path_info_fun, write_probe_fun) do
    case nearest_existing_ancestor(Path.dirname(root), path_info_fun) do
      {:ok, ancestor} -> probe(ancestor, root, :not_creatable, write_probe_fun)
      {:error, kind, reason} -> rejection(kind, root, reason)
    end
  end

  defp nearest_existing_ancestor(path, path_info_fun) do
    case path_info_fun.(path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, path}
      {:ok, %File.Stat{type: type}} -> {:error, :not_creatable, {:not_directory, type}}
      {:error, :enoent} -> next_ancestor(path, path_info_fun)
      {:error, :enotdir} -> {:error, :not_creatable, :enotdir}
      {:error, reason} -> {:error, :unreadable, reason}
    end
  end

  defp next_ancestor(path, path_info_fun) do
    parent = Path.dirname(path)
    if parent == path, do: {:error, :not_creatable, :enoent}, else: nearest_existing_ancestor(parent, path_info_fun)
  end

  defp probe(path, kind, write_probe_fun), do: probe(path, path, kind, write_probe_fun)

  defp probe(path, rejection_path, kind, write_probe_fun) do
    case write_probe_fun.(path) do
      :ok -> :ok
      {:error, reason} -> rejection(kind, rejection_path, reason)
    end
  end

  defp write_probe(path) do
    probe = Path.join(path, ".symphony-write-probe-#{System.unique_integer([:positive, :monotonic])}")

    case File.mkdir(probe) do
      :ok -> File.rmdir(probe)
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_disk_space(settings, opts) do
    disk_opts = Keyword.take(opts, [:free_bytes_fun])

    case WorkspaceDiskGuard.check(settings, disk_opts) do
      {:ok, _summary} ->
        :ok

      {:error, %{reason: kind} = reason} when kind in [:low_disk_space, :disk_space_unavailable] ->
        {:error, %{kind: kind, path: reason |> Map.fetch!(:root) |> Path.expand(), reason: reason}}
    end
  end

  defp rejection(kind, path, reason), do: {:error, %{kind: kind, path: Path.expand(path), reason: reason}}
end

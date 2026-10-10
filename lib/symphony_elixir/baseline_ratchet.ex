defmodule SymphonyElixir.BaselineRatchet do
  @moduledoc false

  @type baseline_replacement :: :delete | {:replace, String.t()}
  @type expansion(key) :: %{
          required(:base_count) => non_neg_integer(),
          required(:current_count) => pos_integer(),
          required(:key) => key
        }

  @spec baseline_candidate([entry], ([entry] -> iodata())) :: baseline_replacement when entry: term()
  def baseline_candidate([], _encode), do: :delete

  def baseline_candidate(entries, encode) do
    content = entries |> encode.() |> IO.iodata_to_binary()
    {:replace, if(String.ends_with?(content, "\n"), do: content, else: content <> "\n")}
  end

  @spec merge_base_baseline(String.t(), String.t(), (String.t() -> {:ok, baseline} | {:error, String.t()})) ::
          {:ok, String.t(), :missing | baseline} | {:error, String.t()}
        when baseline: term()
  def merge_base_baseline(root, path, parse) do
    case System.cmd("git", ["merge-base", "HEAD", "origin/main"], cd: root, stderr_to_stdout: true) do
      {merge_base, 0} ->
        revision = String.trim(merge_base)
        load_revision_baseline(root, path, revision, parse)

      {output, status} ->
        {:error, "baseline.merge_base: git exited #{status}: #{String.trim(output)}"}
    end
  end

  @spec multiset_ceiling([current], [base], (current | base -> key)) ::
          :ok | {:error, [expansion(key)]}
        when current: term(), base: term(), key: term()
  def multiset_ceiling(current, base, key) do
    current_counts = Enum.frequencies_by(current, key)
    base_counts = Enum.frequencies_by(base, key)

    expansions =
      current_counts
      |> Enum.flat_map(fn {item, current_count} ->
        base_count = Map.get(base_counts, item, 0)

        if current_count > base_count do
          [%{key: item, current_count: current_count, base_count: base_count}]
        else
          []
        end
      end)
      |> Enum.sort_by(&inspect(&1.key))

    if expansions == [], do: :ok, else: {:error, expansions}
  end

  @spec replace_baseline(String.t(), baseline_replacement(), [String.t()]) ::
          {:ok, :deleted | :unchanged | :written} | {:error, [String.t()]}
  def replace_baseline(_path, _candidate, [_error | _rest] = errors), do: {:error, errors}

  def replace_baseline(path, :delete, []) do
    case File.rm(path) do
      :ok -> {:ok, :deleted}
      {:error, :enoent} -> {:ok, :unchanged}
      {:error, reason} -> {:error, ["baseline.file: cannot delete #{path}: #{inspect(reason)}"]}
    end
  end

  def replace_baseline(path, {:replace, content}, []) do
    case File.read(path) do
      {:ok, ^content} ->
        {:ok, :unchanged}

      _current ->
        case File.write(path, content) do
          :ok -> {:ok, :written}
          {:error, reason} -> {:error, ["baseline.file: cannot write #{path}: #{inspect(reason)}"]}
        end
    end
  end

  defp load_revision_baseline(root, path, revision, parse) do
    case System.cmd("git", ["ls-tree", "--name-only", revision, "--", path], cd: root, stderr_to_stdout: true) do
      {"", 0} ->
        {:ok, revision, :missing}

      {_listed_path, 0} ->
        parse_revision_baseline(root, path, revision, parse)

      {output, status} ->
        {:error, "baseline.merge_base: git ls-tree exited #{status}: #{String.trim(output)}"}
    end
  end

  defp parse_revision_baseline(root, path, revision, parse) do
    case System.cmd("git", ["show", "#{revision}:#{path}"], cd: root, stderr_to_stdout: true) do
      {content, 0} ->
        case parse.(content) do
          {:ok, baseline} -> {:ok, revision, baseline}
          {:error, _reason} = error -> error
        end

      {output, status} ->
        {:error, "baseline.merge_base: git show exited #{status}: #{String.trim(output)}"}
    end
  end
end

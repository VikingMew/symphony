defmodule SymphonyElixir.Worker.Cleanup do
  @moduledoc "Age-bounded cleanup that preserves active lease directories."

  alias SymphonyElixir.Worker.Paths

  @spec remove_expired(Path.t(), MapSet.t(Path.t()), non_neg_integer(), DateTime.t()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def remove_expired(root, active, max_age_seconds, now) do
    with {:ok, entries} <- File.ls(root) do
      entries
      |> Enum.map(&Path.join(root, &1))
      |> Enum.reduce_while({:ok, []}, fn target, {:ok, removed} ->
        with false <- MapSet.member?(active, target),
             {:ok, stat} <- File.stat(target, time: :posix),
             true <- DateTime.to_unix(now) - stat.mtime > max_age_seconds do
          case Paths.remove_contained(root, target) do
            :ok -> {:cont, {:ok, [target | removed]}}
            error -> {:halt, error}
          end
        else
          _ -> {:cont, {:ok, removed}}
        end
      end)
      |> case do
        {:ok, removed} -> {:ok, Enum.reverse(removed)}
        error -> error
      end
    end
  end
end

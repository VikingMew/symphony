defmodule SymphonyElixir.Worker.Validation do
  @moduledoc "Ordered validation gate execution and secret-free local summary."

  @outcomes [:passed, :failed, :timed_out, :cancelled, :toolchain_unavailable]
  @type outcome :: :passed | :failed | :timed_out | :cancelled | :toolchain_unavailable

  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @spec run([map()], Path.t(), (map(), Path.t() -> map())) :: map()
  def run(gates, cwd, runner \\ &SymphonyElixir.Worker.Command.run/2) do
    {results, overall} =
      Enum.reduce_while(gates, {[], :passed}, fn gate, {results, :passed} ->
        result = runner.(gate, cwd)
        status = Map.fetch!(result, :status)
        next = {results ++ [Map.put(result, :command, gate.command)], status}
        if status == :passed, do: {:cont, next}, else: {:halt, next}
      end)

    %{overall_status: overall, gates: results}
  end

  @spec write!(Path.t(), map()) :: :ok
  def write!(path, summary) do
    safe = SymphonyElixir.Redaction.payload(summary, 4_096)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode_to_iodata!(safe, pretty: true))
  end
end

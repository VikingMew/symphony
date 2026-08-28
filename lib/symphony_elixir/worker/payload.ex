defmodule SymphonyElixir.Worker.Payload do
  @moduledoc "Validated slice-1 execution payload consumed from worker-v1."

  @enforce_keys [:repository, :revision, :branch, :codex, :gates]
  defstruct @enforce_keys ++ [hooks: [], handoff: %{}]

  @type command :: %{required(:command) => String.t(), required(:timeout_seconds) => pos_integer()}
  @type t :: %__MODULE__{repository: String.t(), revision: String.t(), branch: String.t(), codex: command(), hooks: [command()], gates: [command()], handoff: map()}

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_execution_payload, String.t()}}
  def parse(%{"version" => 1} = payload) do
    with {:ok, repository} <- required_string(payload, "repository"),
         {:ok, revision} <- required_string(payload, "revision"),
         {:ok, branch} <- required_string(payload, "branch"),
         {:ok, codex} <- command(Map.get(payload, "codex"), "codex"),
         {:ok, hooks} <- commands(Map.get(payload, "hooks", []), "hooks", true),
         {:ok, gates} <- commands(Map.get(payload, "required_gates"), "required_gates", false) do
      {:ok, %__MODULE__{repository: repository, revision: revision, branch: branch, codex: codex, hooks: hooks, gates: gates, handoff: Map.get(payload, "handoff", %{})}}
    end
  end

  def parse(%{"version" => version}), do: error("unsupported version #{inspect(version)}")
  def parse(_), do: error("version is required")

  defp commands(value, name, allow_empty) when is_list(value) do
    if value == [] and not allow_empty do
      error("#{name} must not be empty")
    else
      value
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
        case command(item, "#{name}[#{index}]") do
          {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
        error -> error
      end
    end
  end

  defp commands(_, name, _allow_empty), do: error("#{name} must be a list")

  defp command(%{"command" => command, "timeout_seconds" => timeout}, _name)
       when is_binary(command) and command != "" and is_integer(timeout) and timeout > 0,
       do: {:ok, %{command: command, timeout_seconds: timeout}}

  defp command(_, name), do: error("#{name} requires command and positive timeout_seconds")

  defp required_string(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> error("#{key} is required")
    end
  end

  defp error(message), do: {:error, {:invalid_execution_payload, message}}
end

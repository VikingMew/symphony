defmodule SymphonyElixir.Worker.Payload do
  @moduledoc "Validated slice-1 execution payload consumed from worker-v1."

  @enforce_keys [:repository, :revision, :branch, :codex, :gates]
  defstruct @enforce_keys ++ [hooks: [], handoff: %{}]

  @type command :: %{required(:command) => String.t(), required(:timeout_seconds) => pos_integer()}
  @type t :: %__MODULE__{
          repository: String.t(),
          revision: String.t(),
          branch: String.t(),
          codex: command(),
          hooks: [command()],
          gates: [command()],
          handoff: map()
        }

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_execution_payload, String.t()}}
  def parse(%{"version" => 1} = payload) do
    with :ok <- reject_forbidden(payload),
         {:ok, repository} <- required_string(payload, "repository"),
         :ok <- reject_repository_credentials(repository),
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
      case parse_commands(value, name) do
        {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
        error -> error
      end
    end
  end

  defp commands(_, name, _allow_empty), do: error("#{name} must be a list")

  defp parse_commands(value, name) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      reduce_command(command(item, "#{name}[#{index}]"), acc)
    end)
  end

  defp reduce_command({:ok, parsed}, acc), do: {:cont, {:ok, [parsed | acc]}}
  defp reduce_command(error, _acc), do: {:halt, error}

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

  defp reject_forbidden(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      reduce_forbidden(key, item)
    end)
  end

  defp reject_forbidden(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case reject_forbidden(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_forbidden(_value), do: :ok

  defp reduce_forbidden(key, item) do
    normalized = String.downcase(to_string(key))

    if normalized == "workflow_version_id" or
         String.contains?(normalized, ["token", "secret", "password", "credential", "authorization"]) do
      {:halt, error("forbidden field #{key}")}
    else
      continue_forbidden(reject_forbidden(item))
    end
  end

  defp continue_forbidden(:ok), do: {:cont, :ok}
  defp continue_forbidden(error), do: {:halt, error}

  defp reject_repository_credentials(repository) do
    case URI.parse(repository) do
      %URI{userinfo: userinfo} when is_binary(userinfo) and userinfo != "" -> error("repository credentials are forbidden")
      _ -> :ok
    end
  end

  defp error(message), do: {:error, {:invalid_execution_payload, message}}
end

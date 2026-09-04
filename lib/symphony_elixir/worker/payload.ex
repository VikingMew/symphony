defmodule SymphonyElixir.Worker.Payload do
  @moduledoc "Validated slice-1 execution payload consumed from worker-v1."

  alias SymphonyElixir.Config.Schema

  @codex_config_fields ~w(
    command
    pre_start_commands
    approval_policy
    thread_sandbox
    turn_sandbox_policy
    turn_timeout_ms
    read_timeout_ms
    stall_timeout_ms
  )

  @enforce_keys [:repository, :default_branch, :branch, :codex, :gates]
  defstruct @enforce_keys ++ [repository_url: nil, hooks: [], handoff: %{}]

  @type command :: %{required(:command) => String.t(), required(:timeout_seconds) => pos_integer()}
  @type codex :: %{
          required(:prompt) => String.t(),
          required(:profile) => String.t(),
          required(:issue) => %{required(:identifier) => String.t(), required(:title) => String.t()},
          required(:config) => map()
        }
  @type t :: %__MODULE__{
          repository: String.t(),
          repository_url: String.t(),
          default_branch: String.t(),
          branch: String.t(),
          codex: codex(),
          hooks: [command()],
          gates: [command()],
          handoff: map()
        }

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_execution_payload, String.t()}}
  def parse(%{"version" => 1} = payload) do
    with :ok <- reject_forbidden(payload),
         {:ok, repository} <- required_string(payload, "repository"),
         :ok <- reject_repository_credentials(repository),
         {:ok, default_branch} <- required_string(payload, "default_branch"),
         {:ok, branch} <- required_string(payload, "branch"),
         {:ok, codex} <- codex(Map.get(payload, "codex")),
         {:ok, hooks} <- commands(Map.get(payload, "hooks", []), "hooks", true),
         {:ok, gates} <- commands(Map.get(payload, "required_gates"), "required_gates", true) do
      {:ok,
       %__MODULE__{
         repository: repository,
         repository_url: Map.get(payload, "repository_url", repository),
         default_branch: default_branch,
         branch: branch,
         codex: codex,
         hooks: hooks,
         gates: gates,
         handoff: Map.get(payload, "handoff", %{})
       }}
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

  defp codex(%{} = payload) do
    with {:ok, prompt} <- required_string(payload, "prompt"),
         {:ok, profile} <- required_string(payload, "profile"),
         {:ok, issue} <- codex_issue(Map.get(payload, "issue")),
         {:ok, config} <- codex_config(payload) do
      {:ok, %{prompt: prompt, profile: profile, issue: issue, config: config}}
    end
  end

  defp codex(_value), do: invalid_codex()

  defp codex_issue(%{} = issue) do
    with {:ok, identifier} <- required_string(issue, "identifier"),
         {:ok, title} <- required_string(issue, "title") do
      {:ok, %{identifier: identifier, title: title}}
    end
  end

  defp codex_issue(_issue), do: invalid_codex()

  defp codex_config(
         %{
           "command" => _command,
           "pre_start_commands" => _pre_start_commands,
           "approval_policy" => _approval_policy,
           "thread_sandbox" => _thread_sandbox,
           "turn_sandbox_policy" => _turn_sandbox_policy,
           "turn_timeout_ms" => _turn_timeout_ms,
           "read_timeout_ms" => _read_timeout_ms,
           "stall_timeout_ms" => _stall_timeout_ms
         } = payload
       ) do
    case Schema.parse(%{"codex" => Map.take(payload, @codex_config_fields)}) do
      {:ok, settings} ->
        config = settings |> Schema.to_external_config() |> Map.fetch!("codex")
        {:ok, Map.take(config, @codex_config_fields)}

      {:error, _reason} ->
        invalid_codex()
    end
  end

  defp codex_config(_payload), do: invalid_codex()

  defp invalid_codex do
    error("codex requires app-server settings, prompt, profile, and issue context")
  end

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

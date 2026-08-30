defmodule SymphonyElixir.Worker.ExecutionPayload do
  @moduledoc "Converts a persisted Panel task snapshot into the worker-v1 execution contract."

  @hook_names ~w(after_create before_run after_run before_remove)

  @spec from_task_payload(map()) :: map()
  def from_task_payload(payload) when is_map(payload) do
    repository = Map.fetch!(payload, "repository")
    limits = Map.fetch!(payload, "limits")

    %{
      "version" => 1,
      "repository" => Map.fetch!(repository, "url"),
      "revision" => Map.fetch!(repository, "source_ref"),
      "branch" => Map.fetch!(repository, "implementation_branch"),
      "codex" => %{
        "command" => codex_command(payload),
        "timeout_seconds" => seconds(Map.fetch!(limits, "turn_timeout_ms"))
      },
      "hooks" => hooks(Map.fetch!(payload, "hooks")),
      "required_gates" => Enum.map(Map.fetch!(payload, "required_gates"), &command/1),
      "handoff" => handoff(Map.fetch!(payload, "handoff"), Map.fetch!(repository, "implementation_branch"))
    }
  end

  defp codex_command(payload) do
    command = payload |> Map.fetch!("codex") |> Map.fetch!("command") |> exec_command()
    command <> " -- " <> shell(prompt(payload))
  end

  defp exec_command(command) do
    if String.ends_with?(command, "app-server") do
      String.replace_suffix(command, "app-server", "exec --json")
    else
      command
    end
  end

  defp prompt(payload) do
    issue = Map.fetch!(payload, "issue")

    """
    Workflow profile: #{Map.fetch!(payload, "workflow_profile")}

    #{Map.fetch!(payload, "prompt")}

    Linear issue #{Map.fetch!(issue, "identifier")}: #{Map.fetch!(issue, "title")}

    #{Map.get(issue, "description") || ""}
    """
    |> String.trim()
  end

  defp hooks(%{"timeout_ms" => timeout} = hooks) do
    for name <- @hook_names,
        value = Map.get(hooks, name),
        is_binary(value) and value != "" do
      %{"command" => value, "timeout_seconds" => seconds(timeout)}
    end
  end

  defp command(%{"command" => command, "timeout_ms" => timeout}) do
    %{"command" => command, "timeout_seconds" => seconds(timeout)}
  end

  defp handoff(%{"command" => _command} = handoff, _branch), do: handoff

  defp handoff(handoff, branch) do
    Map.merge(handoff, %{
      "command" => "printf 'SYMPHONY_HANDOFF_BRANCH=%s\\nSYMPHONY_HANDOFF_COMMIT=%s\\n' #{shell(branch)} \"$(git rev-parse HEAD)\"",
      "timeout_seconds" => 60
    })
  end

  defp seconds(milliseconds), do: div(milliseconds + 999, 1_000)
  defp shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

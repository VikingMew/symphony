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
      "codex" => codex(payload, limits),
      "hooks" => hooks(Map.fetch!(payload, "hooks")),
      "required_gates" => Enum.map(Map.fetch!(payload, "required_gates"), &command/1),
      "handoff" => Map.fetch!(payload, "handoff")
    }
  end

  defp codex(payload, limits) do
    codex = Map.fetch!(payload, "codex")
    issue = Map.fetch!(payload, "issue")

    %{
      "command" => Map.fetch!(codex, "command"),
      "pre_start_commands" => Map.fetch!(codex, "pre_start_commands"),
      "approval_policy" => Map.fetch!(codex, "approval_policy"),
      "thread_sandbox" => Map.fetch!(codex, "thread_sandbox"),
      "turn_sandbox_policy" => Map.fetch!(codex, "turn_sandbox_policy"),
      "turn_timeout_ms" => Map.fetch!(limits, "turn_timeout_ms"),
      "read_timeout_ms" => Map.fetch!(limits, "read_timeout_ms"),
      "stall_timeout_ms" => Map.fetch!(limits, "stall_timeout_ms"),
      "prompt" => prompt(payload),
      "profile" => Map.fetch!(payload, "workflow_profile"),
      "issue" => Map.take(issue, ["identifier", "title"])
    }
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

  defp seconds(milliseconds), do: div(milliseconds + 999, 1_000)
end

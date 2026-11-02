defmodule SymphonyElixir.Worker.CodexOptions do
  @moduledoc "Builds the app-server options for one worker execution."

  alias SymphonyElixir.Worker.{Config, Payload}

  @spec for_run(Config.t(), map(), Payload.t(), map(), keyword()) :: keyword()
  def for_run(config, claim, payload, codex, callbacks) do
    opts = [
      profile: codex.profile,
      run_id: Map.fetch!(claim, "run_id"),
      on_message: Keyword.fetch!(callbacks, :on_message),
      dynamic_tool_opts: [
        allowed_updates: Map.get(payload.handoff, "allowed_updates", %{}),
        audit_recorder: Keyword.fetch!(callbacks, :audit_recorder),
        task_id: Map.fetch!(claim, "task_id"),
        graphql: Keyword.fetch!(callbacks, :graphql),
        pull_request_proof_secret: Keyword.fetch!(callbacks, :proof_secret),
        pull_request_creator: Keyword.fetch!(callbacks, :pull_request_creator)
      ]
    ]

    if config.codex_launcher, do: Keyword.put(opts, :launch_command, config.codex_launcher), else: opts
  end
end

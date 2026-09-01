defmodule SymphonyElixir.Worker.Executor do
  @moduledoc "Lease-owned preparation, execution, validation, and handoff pipeline."

  alias SymphonyElixir.Codex.{AppServer, DynamicTool}
  alias SymphonyElixir.Config, as: RuntimeConfig
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Worker.{Command, Config, Paths, Payload, Validation}

  @spec execute(Config.t(), map()) :: map()
  def execute(config, claim) do
    Process.flag(:trap_exit, true)

    with {:ok, payload} <- Payload.parse(claim["execution"]),
         {:ok, workspace} <- Paths.lease_dir(config, claim["project_id"], claim["task_id"], claim["lease_id"]),
         {:ok, log_dir} <- Paths.log_dir(config, claim["task_id"], claim["lease_id"]),
         :ok <- File.mkdir_p(workspace),
         :ok <- not_cancelled(),
         {:ok, revision} <- prepare(payload, workspace),
         :ok <- run_steps(payload.hooks, workspace, :hook_failed),
         :ok <- not_cancelled(),
         %{status: :passed} = codex <- run_codex(config, claim, payload, workspace),
         {:ok, validation} <- validate(config, claim, revision, codex, payload.gates, workspace, log_dir),
         :ok <- not_cancelled(),
         {:ok, handoff} <- handoff(claim, payload, codex) do
      summary = summary(config, claim, revision, codex, validation)
      Validation.write!(Path.join(log_dir, "validation.json"), summary)
      Map.merge(summary, %{status: :completed, phase: :handoff, handoff: handoff})
    else
      :cancelled ->
        cancelled_result()

      {:validation_cancelled, summary} ->
        Map.merge(summary, Map.merge(cancelled_result(), %{phase: :validation}))

      {:validation_failed, summary} ->
        Map.merge(summary, %{status: :failed, phase: :validation})

      {:error, reason} ->
        %{status: :failed, reason: inspect(reason)}

      %{status: :cancelled} = result ->
        Map.put(cancelled_result(), :detail, result.detail)

      %{status: status} = result ->
        %{status: :failed, reason: status, detail: result.detail}

      status when status in [:failed, :timed_out, :cancelled, :toolchain_unavailable] ->
        %{status: :failed, reason: status}
    end
  end

  defp run_codex(config, claim, payload, workspace) do
    codex = payload.codex
    started = System.monotonic_time(:millisecond)
    proof_secret = :crypto.strong_rand_bytes(32)

    result =
      RuntimeConfig.with_workflow_context(codex_workflow(config, codex), fn ->
        issue = %Issue{
          id: Map.fetch!(claim, "issue_id"),
          identifier: codex.issue.identifier,
          title: codex.issue.title,
          branch_name: payload.branch,
          url: Map.get(payload.handoff, "issue_url")
        }

        AppServer.run(workspace, codex.prompt, issue,
          profile: codex.profile,
          run_id: Map.fetch!(claim, "run_id"),
          dynamic_tool_opts: [
            pull_request_proof_secret: proof_secret,
            pull_request_creator: fn issue, rendered, _opts ->
              PullRequest.ensure_open(issue, RuntimeConfig.settings!().project, rendered, [])
            end
          ]
        )
      end)

    duration_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, app_server_result} ->
        %{
          status: :passed,
          session_id: Map.fetch!(app_server_result, :session_id),
          handoff: Map.fetch!(app_server_result, :handoff),
          proof_secret: proof_secret,
          duration_ms: duration_ms
        }

      {:error, reason} ->
        %{status: :failed, duration_ms: duration_ms, detail: inspect(reason)}
    end
  end

  defp codex_workflow(config, codex) do
    %{
      config: %{
        "workspace" => %{"root" => config.workspace_root},
        "codex" => codex.config
      },
      prompt: "",
      prompt_template: ""
    }
  end

  defp prepare(payload, workspace) do
    with :ok <- not_cancelled(),
         %{status: :passed} <- Command.run(%{command: "git clone --no-checkout -- #{shell(payload.repository)} .", timeout_seconds: 300}, workspace),
         :ok <- not_cancelled(),
         %{status: :passed} <- Command.run(%{command: "git checkout --detach #{shell(payload.revision)} && git rev-parse HEAD", timeout_seconds: 120}, workspace),
         {revision, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: workspace) do
      {:ok, String.trim(revision)}
    else
      :cancelled -> :cancelled
      %{status: :cancelled} = result -> result
      result -> {:error, {:source_preparation_failed, result}}
    end
  end

  defp run_steps(steps, workspace, failure) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      with :ok <- not_cancelled(),
           %{status: :passed} <- Command.run(step, workspace) do
        {:cont, :ok}
      else
        %{status: :cancelled} = result -> {:halt, result}
        :cancelled -> {:halt, %{status: :cancelled, detail: "cancelled before phase"}}
        result -> {:halt, {:error, {failure, result}}}
      end
    end)
  end

  defp run_gate(gate, workspace) do
    case not_cancelled() do
      :ok -> Command.run(gate, workspace)
      :cancelled -> %{status: :cancelled, exit_code: nil, duration_ms: 0, detail: "cancelled before gate"}
    end
  end

  defp validate(config, claim, revision, codex, gates, workspace, log_dir) do
    validation = Validation.run(gates, workspace, &run_gate/2)
    summary = summary(config, claim, revision, codex, validation)
    Validation.write!(Path.join(log_dir, "validation.json"), summary)

    case validation.overall_status do
      :passed -> {:ok, validation}
      :cancelled -> {:validation_cancelled, summary}
      _ -> {:validation_failed, summary}
    end
  end

  defp handoff(claim, payload, codex) do
    update = Map.put(codex.handoff, "target_state", "Ready to Merge")

    response =
      DynamicTool.execute("linear_task_update", update,
        issue: %Issue{id: Map.fetch!(claim, "issue_id")},
        profile: payload.codex.profile,
        session_id: codex.session_id,
        pull_request_proof_secret: codex.proof_secret
      )

    case response do
      %{"success" => true} ->
        references = Map.fetch!(codex.handoff, "references")
        {:ok, references |> Map.take(["branch", "commit", "pr_url", "pr_proof"]) |> Map.put("linear_state", "Ready to Merge")}

      %{"success" => false, "output" => output} ->
        {:error, {:handoff_failed, output}}
    end
  end

  defp summary(config, claim, revision, codex, validation) do
    %{
      envelope: Map.take(claim, ["task_id", "lease_id", "project_id", "run_id"]),
      source_revision: revision,
      runtime_identity: %{image: config.image_reference, worker_source_revision: config.source_revision},
      codex: %{session_id: Map.get(codex, :session_id), duration_ms: codex.duration_ms, outcome: codex.status},
      validation: validation
    }
  end

  defp not_cancelled do
    if Process.get(:worker_cancelled) do
      :cancelled
    else
      receive do
        {:EXIT, from, :shutdown} when is_pid(from) ->
          Process.put(:worker_cancelled, true)
          :cancelled
      after
        0 -> :ok
      end
    end
  end

  defp cancelled_result do
    %{
      status: :cancelled,
      reason: :operator_requested,
      descendants_reaped: true,
      cleanup: :quarantined
    }
  end

  defp shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

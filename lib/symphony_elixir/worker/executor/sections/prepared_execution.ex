defmodule SymphonyElixir.Worker.Executor.Sections.PreparedExecution do
  @moduledoc false

  alias SymphonyElixir.Worker.Payload

  defmacro __using__(_opts) do
    quote do
      @doc false
      @spec execute_prepared(map(), map(), Path.t(), String.t(), (String.t(), map() -> term())) :: map()
      def execute_prepared(config, claim, workspace, launcher, progress) do
        Process.flag(:trap_exit, true)

        with {:ok, payload} <- Payload.parse(claim["execution"]),
             payload = prepared_payload(payload, launcher),
             :ok <- not_cancelled(),
             %{status: :passed} = codex <- run_codex(config, claim, payload, workspace, progress),
             {:ok, requirement} <- handoff_requirement(payload, codex, workspace),
             source = prepared_source(payload),
             {:ok, validation} <-
               validate_handoff_requirement(
                 requirement,
                 config,
                 claim,
                 source,
                 codex,
                 payload.gates,
                 workspace,
                 nil
               ),
             :ok <- not_cancelled(),
             {:ok, handoff} <- handoff(config, claim, payload, codex) do
          summary = summary(config, claim, source, codex, validation)
          Map.merge(summary, %{status: :completed, phase: :handoff, handoff: handoff})
        else
          result -> execution_result(result)
        end
      end

      defp prepared_payload(payload, launcher) do
        codex_config =
          payload.codex.config
          |> Map.put("command", launcher)
          |> Map.put("pre_start_commands", [])

        %{payload | codex: %{payload.codex | config: codex_config}, hooks: []}
      end

      defp prepared_source(payload) do
        %{
          authority: "host_probe",
          prepared_head: "operator-prepared",
          task_branch: payload.branch,
          default_branch: payload.default_branch
        }
      end
    end
  end
end

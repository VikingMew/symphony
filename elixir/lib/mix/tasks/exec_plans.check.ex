defmodule Mix.Tasks.ExecPlans.Check do
  use Mix.Task

  alias SymphonyElixir.ExecPlanIndex

  @moduledoc """
  Checks that exec plan files are indexed in exactly one lifecycle section.
  """
  @shortdoc "Validates docs/exec-plans README lifecycle index"

  @switches [plans_dir: :string]
  @default_plans_dir "docs/exec-plans"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)
    plans_dir = Keyword.get(opts, :plans_dir, @default_plans_dir)

    case ExecPlanIndex.validate(plans_dir) do
      :ok ->
        Mix.shell().info("exec_plans.check: all exec plans are indexed")
        :ok

      {:error, findings} ->
        shell = Mix.shell()
        Enum.each(findings, &shell.error/1)
        Mix.raise("exec_plans.check failed with #{length(findings)} finding(s)")
    end
  end
end

defmodule SymphonyElixir.TestSupport.LocalitySections.AgentRunner3 do
  @moduledoc false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote context: __CALLER__.module do
      test "implementation preparation failure stops before the first Codex session" do
        test_root = Path.join(System.tmp_dir!(), "agent-runner-preparation-failure-#{System.unique_integer([:positive])}")
        workspace = Path.join(test_root, "workspace")
        File.mkdir_p!(workspace)

        on_exit(fn -> File.rm_rf(test_root) end)

        write_workflow_file!(Workflow.workflow_file_path(),
          project_repository_url: "https://github.com/acme/app",
          project_default_branch: "trunk",
          codex_command: "this-command-must-not-run app-server"
        )

        issue = %Issue{
          id: "issue-preparation-failure",
          identifier: "SYM-160",
          title: "Prepare implementation branch",
          description: "Stop before Codex when preparation fails",
          state: "In Progress",
          branch_name: "feature/sym-160",
          labels: []
        }

        assert {:failed, :merge_conflict} =
                 AgentRunner.run(issue, nil,
                   workspace_creator: fn ^issue, nil, _opts -> {:ok, workspace} end,
                   implementation_branch_preparer: fn ^workspace, "trunk", "feature/sym-160", _opts ->
                     {:error, :merge_conflict}
                   end
                 )
      end
    end
  end
end

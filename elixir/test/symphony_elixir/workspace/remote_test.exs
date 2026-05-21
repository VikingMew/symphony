defmodule SymphonyElixir.Workspace.RemoteTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workspace.Remote

  test "shell_assign expands tilde paths after safe shell assignment" do
    script = Remote.shell_assign("workspace", "~/.symphony/workspaces/MT-1")

    assert script =~ "workspace='~/.symphony/workspaces/MT-1'"
    assert script =~ "case \"$workspace\" in"
    assert script =~ "workspace=\"$HOME/${workspace#~/}\""
  end

  test "parse_workspace_output extracts marker payload and rejects malformed output" do
    assert Remote.parse_workspace_output("noise\n__SYMPHONY_WORKSPACE__\t1\t/home/me/work\n") ==
             {:ok, "/home/me/work", true}

    assert Remote.parse_workspace_output("__SYMPHONY_WORKSPACE__\t0\t/home/me/work\n") ==
             {:ok, "/home/me/work", false}

    assert {:error, {:workspace_prepare_failed, :invalid_output, "no marker"}} =
             Remote.parse_workspace_output("no marker")
  end

  test "hook script and before_remove script keep lifecycle command shape" do
    assert Remote.hook_script("/tmp/work dir", "echo ready") ==
             "cd '/tmp/work dir' && echo ready"

    before_remove = Remote.before_remove_script("~/workspace", "echo cleanup")

    assert before_remove =~ "workspace='~/workspace'"
    assert before_remove =~ "if [ -d \"$workspace\" ]; then"
    assert before_remove =~ "  cd \"$workspace\""
    assert before_remove =~ "  echo cleanup"
  end
end

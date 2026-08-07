defmodule SymphonyElixir.WorkflowValidatorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Workflow, WorkflowValidator}

  test "validates a raw workflow package and returns parsed workflow plus settings" do
    assert {:ok, %{workflow: workflow, settings: settings}} =
             WorkflowValidator.validate_raw(valid_raw(), runtime?: false)

    assert workflow.prompt == "Base prompt"
    assert settings.tracker.kind == "linear"
  end

  test "validates a persisted version through an exporter" do
    previous = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "linear-test-token")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)

    version = %{raw_workflow_md: valid_raw()}

    assert {:ok, %{settings: settings}} =
             WorkflowValidator.validate_version(version, & &1.raw_workflow_md)

    assert settings.project.repository_url == "git@github.com:org/repo.git"
  end

  test "returns workflow validation errors for parse, schema, and semantic failures" do
    assert {:error, {:workflow_validation_failed, message}} = WorkflowValidator.validate_raw("---\n:\n---\n")
    assert message =~ "Failed to parse workflow YAML"

    invalid_schema = "---\ntracker:\n  kind: 123\n---\n"
    assert {:error, {:workflow_validation_failed, message}} = WorkflowValidator.validate_raw(invalid_schema)
    assert message =~ "Invalid workflow config"

    semantic_failure = Workflow.to_markdown(%{"tracker" => %{"kind" => "linear"}}, "Prompt")

    assert {:error, {:workflow_validation_failed, message}} = WorkflowValidator.validate_raw(semantic_failure)
    assert message =~ "Invalid workflow semantics"
  end

  defp valid_raw do
    config =
      Workflow.setup_required_workflow().config
      |> Map.put("project", %{
        "repository_url" => "git@github.com:org/repo.git",
        "default_branch" => "main",
        "checkout_depth" => 1
      })
      |> put_in(["tracker", "project_slug"], "project")

    Workflow.to_markdown(config, "Base prompt")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

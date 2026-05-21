defmodule SymphonyElixir.WorkflowFixturesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport.WorkflowFixtures
  alias SymphonyElixir.Workflow

  test "builds parseable split workflow and profiles package YAML" do
    workflow_yaml = WorkflowFixtures.settings_workflow_yaml()
    profiles_yaml = WorkflowFixtures.settings_profiles_yaml()

    assert {:ok, {:workflow, workflow_part}} = Workflow.parse_settings_yaml(workflow_yaml)
    assert {:ok, {:profiles, profiles_part}} = Workflow.parse_settings_yaml(profiles_yaml)

    assert get_in(workflow_part, ["workflow", "states", "Ready", "profile"]) == "implementation"
    assert get_in(profiles_part, [:profiles, "implementation", "name"]) == "Implementation"
    assert profiles_part[:base_prompt] == "Imported base prompt.\n"
  end

  test "renders stable YAML values for ordinary workflow fixtures" do
    assert WorkflowFixtures.yaml_value("quoted \"value\"") == "\"quoted \\\"value\\\"\""
    assert WorkflowFixtures.yaml_value(["Ready", "In Progress"]) == "[\"Ready\", \"In Progress\"]"
    assert WorkflowFixtures.yaml_value(%{"b" => 2, "a" => 1}) == "{a: 1, b: 2}"
  end
end

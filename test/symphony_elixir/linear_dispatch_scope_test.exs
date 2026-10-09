defmodule SymphonyElixir.LinearDispatchScopeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{DispatchScope, Issue}

  @discovery %{
    teams: [%{key: "KRN", name: "Kernel"}],
    projects: [%{slug: "koroni", teams: [%{key: "KRN"}]}]
  }
  @projects [%{slug: "fallback", enabled: true}, %{slug: "disabled", enabled: false}]

  test "settings validation accepts the three legal combinations" do
    assert :ok = DispatchScope.validate_dispatch_settings(scope("KRN", nil, nil), @discovery, @projects)
    assert :ok = DispatchScope.validate_dispatch_settings(scope("KRN", "koroni", "fallback"), @discovery, @projects)
    assert :ok = DispatchScope.validate_dispatch_settings(scope(nil, nil, nil), @discovery, @projects)
  end

  test "settings validation returns stable typed rejections" do
    assert {:error, :linear_project_requires_team} =
             DispatchScope.validate_dispatch_settings(scope(nil, "koroni", nil), @discovery, @projects)

    assert {:error, {:unknown_linear_team, "NOPE"}} =
             DispatchScope.validate_dispatch_settings(scope("NOPE", nil, nil), @discovery, @projects)

    assert {:error, {:unknown_linear_project, "missing"}} =
             DispatchScope.validate_dispatch_settings(scope("KRN", "missing", nil), @discovery, @projects)

    mismatch = %{teams: [%{key: "KRN"}], projects: [%{slug: "other", teams: [%{key: "OTHER"}]}]}

    assert {:error, {:linear_project_team_mismatch, "KRN", "other"}} =
             DispatchScope.validate_dispatch_settings(scope("KRN", "other", nil), mismatch, @projects)

    assert {:error, {:unknown_fallback_project, "missing"}} =
             DispatchScope.validate_dispatch_settings(scope(nil, nil, "missing"), @discovery, @projects)

    assert {:error, {:disabled_fallback_project, "disabled"}} =
             DispatchScope.validate_dispatch_settings(scope(nil, nil, "disabled"), @discovery, @projects)
  end

  test "project candidates resolve by Linear project and null-project candidates only by fallback" do
    workflows = [
      project_workflow_fixture("project-a", "internal-a", "koroni", ["Ready"]),
      project_workflow_fixture("project-b", "fallback", "other", ["Todo"])
    ]

    project_issue = %Issue{id: "1", team_key: "KRN", project_slug: "koroni", state: "Ready"}

    assert {:ok, %{project_id: "project-a"}, resolved} =
             DispatchScope.resolve_context(project_issue, workflows, scope("KRN", nil, "fallback"))

    assert resolved.context_source == "linear_project"
    assert resolved.symphony_project_slug == "internal-a"

    null_issue = %Issue{id: "2", team_key: "KRN", project_slug: nil, state: "Todo"}

    assert {:ok, %{project_id: "project-b"}, fallback} =
             DispatchScope.resolve_context(null_issue, workflows, scope("KRN", nil, "fallback"))

    assert fallback.context_source == "fallback"

    assert {:error, :missing_fallback_project, rejected} =
             DispatchScope.resolve_context(null_issue, workflows, scope("KRN", nil, nil))

    assert rejected.dispatch_scope.linear_team_key == "KRN"
  end

  test "scope checks reject team and project drift before context selection" do
    workflows = [project_workflow_fixture("project-a", "internal-a", "koroni", ["Ready"])]

    assert {:error, :issue_team_out_of_scope, _issue} =
             DispatchScope.resolve_context(
               %Issue{team_key: "OTHER", project_slug: "koroni"},
               workflows,
               scope("KRN", nil, nil)
             )

    assert {:error, :issue_project_out_of_scope, _issue} =
             DispatchScope.resolve_context(
               %Issue{team_key: "KRN", project_slug: "other"},
               workflows,
               scope("KRN", "koroni", nil)
             )
  end

  test "active state query input is the exact union of enabled workflows" do
    workflows = [
      project_workflow_fixture("a", "a", "a", ["Ready", "Todo"]),
      project_workflow_fixture("b", "b", "b", ["Todo", "Refining"])
    ]

    assert DispatchScope.active_states(workflows) == ["Ready", "Refining", "Todo"]
  end

  defp scope(team, project, fallback) do
    %{linear_team_key: team, linear_project_slug: project, fallback_project_slug: fallback}
  end

  defp project_workflow_fixture(id, slug, linear_slug, active_states) do
    %{
      project_id: id,
      project_slug: slug,
      config: %{"tracker" => %{"project_slug" => linear_slug, "active_states" => active_states}}
    }
  end
end

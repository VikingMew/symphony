defmodule SymphonyElixir.LinearClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.ProjectAuthority
  alias SymphonyElixir.Linear.{CandidateQuery, Client, IssueNormalizer, Pagination}
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.{Tracker, Workflow, WorkflowStore}

  test "candidate fetch requires project context when multiple projects lack configured default" do
    {:ok, project} =
      FakePersistence.create_project(%{
        name: "Symphony",
        slug: "symphony",
        linear_project_slug: "symphony-linear",
        repository_url: "git@github.com:VikingMew/symphony.git",
        enabled: true
      })

    {:ok, loaded} = Workflow.load()
    raw = Workflow.to_markdown(ProjectAuthority.strip(loaded.config), loaded.prompt)
    {:ok, _workflow} = FakePersistence.import_package(project, raw, "test")
    assert :ok = WorkflowStore.force_reload()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    System.delete_env("LINEAR_API_KEY")

    assert {:error, :missing_project_context} = Client.fetch_candidate_issues()
    assert {:error, :missing_project_context} = Tracker.fetch_candidate_issues()
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    assert issue.assigned_to_worker == false
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    {:ok, assignee_filter} = IssueNormalizer.build_assignee_filter("user-1")
    issue = IssueNormalizer.normalize_issue(raw_issue, assignee_filter)

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "candidate query contract uses the exact three dispatch scope filter shapes" do
    fixtures = [
      raw_candidate("krn-koroni", "KRN", "koroni"),
      raw_candidate("krn-null", "KRN", nil),
      raw_candidate("other-project", "OTHER", "other")
    ]

    cases = [
      {%{linear_team_key: "KRN", linear_project_slug: nil, fallback_project_slug: nil}, [:teamKey], ["krn-koroni", "krn-null"], "team_state"},
      {%{linear_team_key: "KRN", linear_project_slug: "koroni", fallback_project_slug: nil}, [:teamKey, :projectSlug], ["krn-koroni"], "team_project_state"},
      {%{linear_team_key: nil, linear_project_slug: nil, fallback_project_slug: nil}, [], ["krn-koroni", "krn-null", "other-project"], "state"}
    ]

    Enum.each(cases, fn {scope, scope_keys, expected_ids, expected_shape} ->
      graphql = fn query, variables ->
        assert variables.stateNames == ["Ready"]
        assert Enum.sort(Map.keys(Map.take(variables, [:teamKey, :projectSlug]))) == Enum.sort(scope_keys)
        assert query =~ "team: {key: {eq: $teamKey}}" == :teamKey in scope_keys
        assert query =~ "project: {slugId: {eq: $projectSlug}}" == :projectSlug in scope_keys
        assert query =~ "team { key }"
        assert query =~ "project { slugId }"

        selected =
          Enum.filter(fixtures, fn issue ->
            (is_nil(variables[:teamKey]) or get_in(issue, ["team", "key"]) == variables.teamKey) and
              (is_nil(variables[:projectSlug]) or
                 get_in(issue, ["project", "slugId"]) == variables.projectSlug)
          end)

        {:ok, candidate_page(selected)}
      end

      assert {:ok, issues} = Client.fetch_candidate_issues_with(scope, ["Ready"], graphql)
      assert Enum.map(issues, & &1.id) == expected_ids
      assert CandidateQuery.scope_filter_shape(scope) == expected_shape
    end)
  end

  test "candidate fetch logs query filter and a successful empty result separately" do
    scope = %{linear_team_key: "KRN", linear_project_slug: nil, fallback_project_slug: nil}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, []} =
                 Client.fetch_candidate_issues_with(scope, ["Ready"], fn _query, _variables ->
                   {:ok, candidate_page([])}
                 end)
      end)

    assert log =~ "event=query_filter"
    assert log =~ "team_key=\"KRN\""
    assert log =~ "filter_shape=team_state"
    assert log =~ "event=fetch_empty"
    assert log =~ "page_count=1 candidate_count=0"
  end

  test "candidate query rejects a project filter without a team as a typed error" do
    scope = %{linear_team_key: nil, linear_project_slug: "koroni", fallback_project_slug: nil}

    assert CandidateQuery.scope_filter_shape(scope) == {:error, :linear_project_requires_team}

    assert CandidateQuery.build(scope, ["Ready"], first: 50, relation_first: 50) ==
             {:error, :linear_project_requires_team}

    assert Client.fetch_candidate_issues_with(scope, ["Ready"], fn _query, _variables ->
             flunk("invalid scope must be rejected before GraphQL")
           end) == {:error, :linear_project_requires_team}
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    {:ok, assignee_filter} = IssueNormalizer.build_assignee_filter("user-1")
    issue = IssueNormalizer.normalize_issue(raw_issue, assignee_filter)

    assert issue.assigned_to_worker == false
  end

  defp raw_candidate(id, team_key, project_slug) do
    %{
      "id" => id,
      "identifier" => String.upcase(id),
      "title" => id,
      "state" => %{"name" => "Ready"},
      "team" => %{"key" => team_key},
      "project" => if(is_nil(project_slug), do: nil, else: %{"slugId" => project_slug}),
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp candidate_page(nodes) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => nodes,
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Pagination.merge_issue_pages([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error,
                {:linear_api_status, 400,
                 %{
                   "errors" => [
                     %{
                       "extensions" => %{"code" => "BAD_USER_INPUT"},
                       "message" => "Variable \"$ids\" got invalid value"
                     }
                   ]
                 }}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear client derives proxy options from runtime environment" do
    proxy_env_names = SymphonyElixir.RuntimeProxy.proxy_env_names()
    previous_proxy_env = Map.new(proxy_env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_proxy_env, fn {name, value} -> restore_env(name, value) end)
    end)

    Enum.each(proxy_env_names, &System.delete_env/1)
    System.put_env("HTTPS_PROXY", "http://user:pass@proxy.example.test:8080")
    System.put_env("HTTP_PROXY", "http://ignored.example.test:8888")

    request_options = Client.request_options("https://api.linear.app/graphql")

    assert Keyword.fetch!(request_options, :timeout) == 30_000
    assert Keyword.fetch!(request_options, :proxy) == {:http, "proxy.example.test", 8080, []}
    assert [{"proxy-authorization", encoded_auth}] = Keyword.fetch!(request_options, :proxy_headers)

    assert Base.decode64!(encoded_auth |> String.trim_leading("Basic ")) == "user:pass"
  end

  test "linear client honors no proxy environment for matching hosts" do
    proxy_env_names = SymphonyElixir.RuntimeProxy.proxy_env_names()
    previous_proxy_env = Map.new(proxy_env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_proxy_env, fn {name, value} -> restore_env(name, value) end)
    end)

    Enum.each(proxy_env_names, &System.delete_env/1)
    System.put_env("HTTPS_PROXY", "http://proxy.example.test:8080")
    System.put_env("NO_PROXY", "localhost, .linear.app")

    assert [timeout: 30_000] = Client.request_options("https://api.linear.app/graphql")
  end

  test "runtime proxy environment redacts credentials for diagnostics" do
    proxy_env_names = SymphonyElixir.RuntimeProxy.proxy_env_names()
    previous_proxy_env = Map.new(proxy_env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_proxy_env, fn {name, value} -> restore_env(name, value) end)
    end)

    Enum.each(proxy_env_names, &System.delete_env/1)
    System.put_env("HTTPS_PROXY", "http://user:pass@proxy.example.test:8080")

    assert SymphonyElixir.RuntimeProxy.redacted_proxy_env() == %{
             "HTTPS_PROXY" => "http://[REDACTED]@proxy.example.test:8080"
           }
  end
end

defmodule SymphonyElixir.GitHub.PullRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  defmodule PullRequest do
    def ensure_open(issue, project, opts) do
      SymphonyElixir.GitHub.PullRequest.ensure_open(issue, project, rendered(), opts)
    end

    defp rendered do
      %{
        title: "SYM-1: Ship PR handoff",
        body: "#### Summary\n\n- handoff\n\n#### Test Plan\n\n- [x] green\n\nFixes SYM-1"
      }
    end
  end

  test "reuses an existing open pull request through gh without creating a duplicate" do
    runner = fn _executable, args, _timeout_ms ->
      send(self(), {:gh, args})

      case args do
        ["auth", "status"] -> {"authenticated", 0}
        ["repo", "view", "acme/app", "--json", "nameWithOwner"] -> {Jason.encode!(%{"nameWithOwner" => "acme/app"}), 0}
        ["api", "--method", "GET", _path] -> {"{}", 0}
        ["pr", "list" | _rest] -> {Jason.encode!([gh_pull_request("OPEN")]), 0}
      end
    end

    assert {:ok,
            %{
              url: "https://github.com/acme/app/pull/12",
              repository: "acme/app",
              base: "main",
              head: "feature/sym-1",
              source: :gh
            }} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: runner
             )

    refute_received {:gh, ["pr", "create" | _rest]}
  end

  test "creates the exact pull request through gh and verifies it after creation" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    runner = fn _executable, args, _timeout_ms ->
      send(test_pid, {:gh, args})

      case args do
        ["auth", "status"] ->
          {"authenticated", 0}

        ["repo", "view", "acme/app", "--json", "nameWithOwner"] ->
          {Jason.encode!(%{"nameWithOwner" => "Acme/App"}), 0}

        ["api", "--method", "GET", _path] ->
          {"{}", 0}

        ["pr", "list" | _rest] ->
          count = Agent.get_and_update(calls, &{&1, &1 + 1})
          if count == 0, do: {"[]", 0}, else: {Jason.encode!([gh_pull_request("OPEN")]), 0}

        ["pr", "create" | _rest] ->
          {"https://github.com/acme/app/pull/12\n", 0}
      end
    end

    assert {:ok, %{url: "https://github.com/acme/app/pull/12", source: :gh}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: runner
             )

    assert_received {:gh, ["pr", "create" | create_args]}
    assert option(create_args, "--repo") == "acme/app"
    assert option(create_args, "--base") == "main"
    assert option(create_args, "--head") == "acme:feature/sym-1"
    assert option(create_args, "--title") == "SYM-1: Ship PR handoff"
    assert option(create_args, "--body") ==
             "#### Summary\n\n- handoff\n\n#### Test Plan\n\n- [x] green\n\nFixes SYM-1"
  end

  test "returns a typed conflict for a closed branch pull request" do
    runner = fn _executable, args, _timeout_ms ->
      case args do
        ["auth", "status"] -> {"authenticated", 0}
        ["repo", "view", "acme/app", "--json", "nameWithOwner"] -> {Jason.encode!(%{"nameWithOwner" => "acme/app"}), 0}
        ["api", "--method", "GET", _path] -> {"{}", 0}
        ["pr", "list" | _rest] -> {Jason.encode!([gh_pull_request("CLOSED")]), 0}
        ["pr", "create" | _rest] -> flunk("closed branch PR must not create an ambiguous duplicate")
      end
    end

    assert {:error, {:pull_request_conflict, "closed", "https://github.com/acme/app/pull/12"}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: runner
             )
  end

  test "fails on a mismatched repository identity before branch or PR operations" do
    runner = fn _executable, args, _timeout_ms ->
      case args do
        ["auth", "status"] -> {"authenticated", 0}
        ["repo", "view", "acme/app", "--json", "nameWithOwner"] -> {Jason.encode!(%{"nameWithOwner" => "other/app"}), 0}
        _ -> flunk("repository mismatch must stop lookup")
      end
    end

    assert {:error, {:github_repository_mismatch, "acme/app", "other/app"}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: runner
             )
  end

  test "falls back to REST, checks before create, and uses proxy-capable HTTP boundary" do
    {:ok, pull_lookups} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    http_request = fn method, url, headers, body, timeout_ms ->
      send(test_pid, {:http, method, url, headers, body, timeout_ms})

      cond do
        method == :get and String.ends_with?(url, "/repos/acme/app") ->
          {:ok, %{status: 200, body: %{"full_name" => "acme/app"}}}

        method == :get and String.contains?(url, "/branches/feature%2Fsym-1") ->
          {:ok, %{status: 200, body: %{}}}

        method == :get and String.contains?(url, "/pulls?") ->
          count = Agent.get_and_update(pull_lookups, &{&1, &1 + 1})
          body = if count == 0, do: [], else: [rest_pull_request()]
          {:ok, %{status: 200, body: body}}

        method == :post and String.ends_with?(url, "/repos/acme/app/pulls") ->
          {:ok, %{status: 201, body: rest_pull_request()}}
      end
    end

    assert {:ok, %{url: "https://github.com/acme/app/pull/12", source: :rest}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: nil,
               token: "rest-token",
               http_request: http_request
             )

    assert_received {:http, :post, "https://api.github.com/repos/acme/app/pulls", headers,
                     %{
                       "title" => "SYM-1: Ship PR handoff",
                       "head" => "feature/sym-1",
                       "base" => "main",
                       "body" => "#### Summary\n\n- handoff\n\n#### Test Plan\n\n- [x] green\n\nFixes SYM-1"
                     }, 30_000}

    assert {"authorization", "Bearer rest-token"} in headers
    assert Agent.get(pull_lookups, & &1) == 2
  end

  test "REST transport failures redact the fallback token" do
    result =
      PullRequest.ensure_open(issue(), project(),
        gh_executable: nil,
        token: "super-secret-token",
        http_request: fn _method, _url, _headers, _body, _timeout ->
          {:error, {:transport, "super-secret-token"}}
        end
      )

    assert {:error, {:github_http_request_failed, details}} = result
    assert details =~ "[REDACTED]"
    refute details =~ "super-secret-token"
  end

  test "missing branch and missing authentication are typed failures" do
    runner = fn _executable, args, _timeout_ms ->
      case args do
        ["auth", "status"] -> {"authenticated", 0}
        ["repo", "view", "acme/app", "--json", "nameWithOwner"] -> {Jason.encode!(%{"nameWithOwner" => "acme/app"}), 0}
        ["api", "--method", "GET", _path] -> {"HTTP 404: Not Found", 1}
      end
    end

    assert {:error, {:remote_branch_not_found, "feature/sym-1"}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: runner
             )

    assert {:error, {:github_auth_unavailable, :gh_not_found, ["GH_TOKEN", "GITHUB_TOKEN"]}} =
             PullRequest.ensure_open(issue(), project(), gh_executable: nil, token: nil)
  end

  test "validates issue and project identity before contacting GitHub" do
    no_client = [gh_executable: nil, token: nil]

    assert {:error, :missing_issue_identifier} =
             PullRequest.ensure_open(%{issue() | identifier: nil}, project(), no_client)

    assert {:error, {:invalid_issue_identifier, "not-linear"}} =
             PullRequest.ensure_open(%{issue() | identifier: "not-linear"}, project(), no_client)

    assert {:error, :missing_issue_title} =
             SymphonyElixir.GitHub.PullRequest.ensure_open(
               issue(),
               project(),
               %{title: "  ", body: "body"},
               no_client
             )

    assert {:error, :invalid_issue_title} =
             SymphonyElixir.GitHub.PullRequest.ensure_open(
               issue(),
               project(),
               %{title: "bad\ntitle", body: "body"},
               no_client
             )

    assert {:error, {:invalid_pull_request_content, :body}} =
             SymphonyElixir.GitHub.PullRequest.ensure_open(
               issue(),
               project(),
               %{title: "SYM-1: title", body: " "},
               no_client
             )

    assert {:error, :missing_default_branch} =
             PullRequest.ensure_open(issue(), %{repository_url: "https://github.com/acme/app"}, no_client)

    assert {:error, :missing_github_repository} =
             PullRequest.ensure_open(issue(), %{default_branch: "main"}, no_client)

    assert {:error, {:unsupported_repository_host, "gitlab.com"}} =
             PullRequest.ensure_open(
               issue(),
               %{default_branch: "main", repository_url: "https://gitlab.com/acme/app"},
               no_client
             )

    assert {:error, :invalid_github_repository_path} =
             PullRequest.ensure_open(
               issue(),
               %{"default_branch" => "main", "repository_url" => "ssh://git@github.com/acme/nested/app"},
               no_client
             )
  end

  test "recovers an ambiguous gh create error by re-reading the exact open pull request" do
    {:ok, lookups} = Agent.start_link(fn -> 0 end)

    runner = fn _executable, args, _timeout_ms ->
      case args do
        ["auth", "status"] ->
          {:ok, "authenticated"}

        ["repo", "view", "acme/app", "--json", "nameWithOwner"] ->
          {:ok, Jason.encode!(%{"nameWithOwner" => "acme/app"})}

        ["api", "--method", "GET", _path] ->
          {:ok, "{}"}

        ["pr", "list" | _rest] ->
          count = Agent.get_and_update(lookups, &{&1, &1 + 1})

          pull_requests =
            if count == 0 do
              []
            else
              [gh_pull_request_without_name_with_owner("OPEN")]
            end

          {:ok, Jason.encode!(pull_requests)}

        ["pr", "create" | _rest] ->
          {:error, :already_exists}
      end
    end

    assert {:ok, %{url: "https://github.com/acme/app/pull/12", source: :gh}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: runner
             )

    assert Agent.get(lookups, & &1) == 2
  end

  test "surfaces unusable gh responses when no REST credential is available" do
    auth_failure = fn _executable, ["auth", "status"], _timeout_ms -> {"login required", 1} end

    assert {:error, {:github_auth_unavailable, :gh, {:github_command_failed, ["auth", "status"], 1, "login required"}}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: auth_failure
             )

    invalid_repo = fn _executable, args, _timeout_ms ->
      case args do
        ["auth", "status"] -> {"authenticated", 0}
        ["repo", "view" | _rest] -> {"not-json", 0}
      end
    end

    assert {:error, {:github_cli_unusable, {:github_cli_invalid_json, _message}}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: "/opt/bin/gh",
               token: nil,
               command_runner: invalid_repo
             )
  end

  test "REST reports repository, branch, and merged-PR conflicts without creating" do
    mismatch = fn :get, url, _headers, _body, _timeout ->
      assert String.ends_with?(url, "/repos/acme/app")
      {:ok, %{status: 200, body: %{"full_name" => "other/app"}}}
    end

    assert {:error, {:github_repository_mismatch, "acme/app", "other/app"}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: nil,
               token: "token",
               http_request: mismatch
             )

    missing_branch = fn method, url, _headers, _body, _timeout ->
      cond do
        method == :get and String.ends_with?(url, "/repos/acme/app") ->
          {:ok, %{status: 200, body: %{"full_name" => "acme/app"}}}

        method == :get and String.contains?(url, "/branches/") ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      end
    end

    assert {:error, {:remote_branch_not_found, "feature/sym-1"}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: nil,
               token: "token",
               http_request: missing_branch
             )

    merged_conflict = fn method, url, _headers, _body, _timeout ->
      cond do
        method == :get and String.ends_with?(url, "/repos/acme/app") ->
          {:ok, %{status: 200, body: %{"full_name" => "acme/app"}}}

        method == :get and String.contains?(url, "/branches/") ->
          {:ok, %{status: 200, body: %{}}}

        method == :get and String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: [%{rest_pull_request() | "state" => "closed", "merged_at" => "2026-08-27T00:00:00Z"}]}}

        method == :post ->
          flunk("merged branch PR must not create a duplicate")
      end
    end

    assert {:error, {:pull_request_conflict, "merged", "https://github.com/acme/app/pull/12"}} =
             PullRequest.ensure_open(issue(), project(),
               gh_executable: nil,
               token: "token",
               http_request: merged_conflict
             )
  end

  defp issue do
    %Issue{
      id: "issue-1",
      identifier: "SYM-1",
      title: "Ship PR handoff",
      state: "In Progress",
      branch_name: "feature/sym-1"
    }
  end

  defp project do
    %Schema.Project{
      repository_url: "git@github.com:acme/app.git",
      default_branch: "main"
    }
  end

  defp gh_pull_request(state) do
    %{
      "state" => state,
      "url" => "https://github.com/acme/app/pull/12",
      "headRefName" => "feature/sym-1",
      "baseRefName" => "main",
      "headRepository" => %{"nameWithOwner" => "acme/app"},
      "headRepositoryOwner" => %{"login" => "acme"}
    }
  end

  defp gh_pull_request_without_name_with_owner(state) do
    gh_pull_request(state)
    |> Map.put("headRepository", %{})
  end

  defp rest_pull_request do
    %{
      "state" => "open",
      "html_url" => "https://github.com/acme/app/pull/12",
      "head" => %{"ref" => "feature/sym-1", "repo" => %{"full_name" => "acme/app"}},
      "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/app"}},
      "merged_at" => nil
    }
  end

  defp option(args, option_name) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^option_name, value] -> value
      _pair -> nil
    end)
  end
end

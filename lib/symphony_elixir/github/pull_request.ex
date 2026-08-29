defmodule SymphonyElixir.GitHub.PullRequest do
  @moduledoc """
  Idempotently ensures an open GitHub pull request for an implementation branch.

  The boundary prefers the `gh` executable available to the Symphony service
  process and falls back to GitHub's REST API when a runtime token is present.
  It never depends on the implementation workspace being mounted locally.
  """

  alias SymphonyElixir.{BranchName, Redaction, RuntimeProxy}
  alias SymphonyElixir.Linear.Issue

  @api_base "https://api.github.com"
  @command_timeout_ms 30_000
  @recent_output_bytes 8_192
  @token_env_names ~w(GH_TOKEN GITHUB_TOKEN)

  @type pull_request :: %{
          url: String.t(),
          repository: String.t(),
          base: String.t(),
          head: String.t(),
          source: :gh | :rest
        }

  @spec ensure_open(Issue.t(), map(), map(), keyword()) ::
          {:ok, pull_request()} | {:error, term()}
  def ensure_open(%Issue{} = issue, project, rendered, opts \\ []) do
    with {:ok, identifier} <- validate_identifier(issue.identifier),
         {:ok, title} <- rendered_title(rendered, identifier),
         {:ok, body} <- rendered_body(rendered, identifier),
         {:ok, head} <- BranchName.validate(issue.branch_name),
         {:ok, base} <- project_default_branch(project),
         {:ok, repository} <- project_repository(project) do
      request = %{
        identifier: identifier,
        title: title,
        body: body,
        repository: repository,
        base: base,
        head: head
      }

      ensure_with_available_client(request, opts)
    end
  end

  defp rendered_value(rendered, field) do
    case Map.get(rendered, field) do
      value when is_binary(value) -> validate_rendered_value(value, field)
      _ -> {:error, {:invalid_pull_request_content, field}}
    end
  end

  defp validate_rendered_value(value, :title), do: validate_title(value)

  defp validate_rendered_value(value, :body) do
    if String.trim(value) == "",
      do: {:error, {:invalid_pull_request_content, :body}},
      else: {:ok, value}
  end

  defp rendered_title(rendered, identifier) do
    with {:ok, title} <- rendered_value(rendered, :title) do
      if String.starts_with?(title, "#{identifier}:"),
        do: {:ok, title},
        else: {:error, {:invalid_pull_request_content, :title_identifier}}
    end
  end

  defp rendered_body(rendered, identifier) do
    with {:ok, body} <- rendered_value(rendered, :body),
         :ok <- validate_no_placeholders(body),
         :ok <- validate_body_section(body, "#### Summary", ~r/^- \S/m),
         :ok <- validate_body_section(body, "#### Test Plan", ~r/^- \[[xX]\] \S/m),
         :ok <- validate_body_order(body),
         :ok <- validate_closing_reference(body, identifier) do
      {:ok, body}
    end
  end

  defp validate_no_placeholders(body) do
    if String.contains?(body, "<!--"),
      do: {:error, {:invalid_pull_request_content, :placeholder}},
      else: :ok
  end

  defp validate_body_section(body, heading, shape) do
    case :binary.match(body, heading) do
      :nomatch ->
        {:error, {:invalid_pull_request_content, heading}}

      {_position, _length} ->
        section =
          body
          |> String.split(heading, parts: 2)
          |> List.last()
          |> String.split("####", parts: 2)
          |> hd()

        if Regex.match?(shape, section), do: :ok, else: {:error, {:invalid_pull_request_content, heading}}
    end
  end

  defp validate_body_order(body) do
    {summary, _} = :binary.match(body, "#### Summary")
    {test_plan, _} = :binary.match(body, "#### Test Plan")
    if summary < test_plan, do: :ok, else: {:error, {:invalid_pull_request_content, :section_order}}
  end

  defp validate_closing_reference(body, identifier) do
    reference = "Fixes #{identifier}"
    matches = Regex.scan(~r/^Fixes [A-Z][A-Z0-9]+-\d+$/m, body) |> Enum.map(&hd/1)

    if matches == [reference] and body |> String.trim() |> String.ends_with?(reference),
      do: :ok,
      else: {:error, {:invalid_pull_request_content, :closing_reference}}
  end

  defp ensure_with_available_client(request, opts) do
    token = github_token(opts)

    case gh_executable(opts) do
      nil ->
        ensure_with_rest_or_auth_error(request, token, opts, :gh_not_found)

      executable ->
        executable
        |> ensure_with_gh(request, opts)
        |> handle_gh_result(request, token, opts)
    end
  end

  defp handle_gh_result({:ok, pull_request}, _request, _token, _opts),
    do: {:ok, pull_request}

  defp handle_gh_result({:error, reason}, request, token, opts) do
    if domain_error?(reason),
      do: {:error, reason},
      else: ensure_with_rest_or_auth_error(request, token, opts, reason)
  end

  defp ensure_with_rest_or_auth_error(_request, nil, _opts, :gh_not_found) do
    {:error, {:github_auth_unavailable, :gh_not_found, @token_env_names}}
  end

  defp ensure_with_rest_or_auth_error(_request, nil, _opts, {:github_cli_auth_failed, details}) do
    {:error, {:github_auth_unavailable, :gh, details}}
  end

  defp ensure_with_rest_or_auth_error(_request, nil, _opts, reason),
    do: {:error, {:github_cli_unusable, reason}}

  defp ensure_with_rest_or_auth_error(request, token, opts, _cli_reason),
    do: ensure_with_rest(request, token, opts)

  defp ensure_with_gh(executable, request, opts) do
    with {:ok, _auth} <- gh_auth_status(executable, opts),
         {:ok, actual_repository} <- gh_repository_identity(executable, request.repository, opts),
         :ok <- validate_repository_identity(request.repository, actual_repository),
         :ok <- gh_branch_exists(executable, request.repository, request.head, opts),
         {:ok, pull_requests} <- gh_pull_requests(executable, request, opts) do
      ensure_from_lookup(pull_requests, request, fn -> gh_create(executable, request, opts) end)
    end
  end

  defp gh_auth_status(executable, opts) do
    case run_gh(executable, ["auth", "status"], opts) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, {:github_cli_auth_failed, reason}}
    end
  end

  defp gh_repository_identity(executable, repository, opts) do
    with {:ok, output} <-
           run_gh(executable, ["repo", "view", repository, "--json", "nameWithOwner"], opts),
         {:ok, %{"nameWithOwner" => actual}} when is_binary(actual) <- Jason.decode(output) do
      {:ok, actual}
    else
      {:ok, other} -> {:error, {:github_cli_invalid_repository_response, safe_output(inspect(other))}}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:github_cli_invalid_json, Exception.message(reason)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gh_branch_exists(executable, repository, branch, opts) do
    path = "repos/#{repository}/branches/#{encode_path_segment(branch)}"

    case run_gh(executable, ["api", "--method", "GET", path], opts) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        if not_found_error?(reason),
          do: {:error, {:remote_branch_not_found, branch}},
          else: {:error, reason}
    end
  end

  defp gh_pull_requests(executable, request, opts) do
    args = [
      "pr",
      "list",
      "--repo",
      request.repository,
      "--state",
      "all",
      "--head",
      "#{repository_owner(request.repository)}:#{request.head}",
      "--base",
      request.base,
      "--limit",
      "100",
      "--json",
      "state,url,headRefName,baseRefName,headRepository,headRepositoryOwner"
    ]

    with {:ok, output} <- run_gh(executable, args, opts),
         {:ok, pull_requests} when is_list(pull_requests) <- Jason.decode(output) do
      {:ok, Enum.map(pull_requests, &normalize_gh_pull_request(&1, request.repository))}
    else
      {:ok, other} -> {:error, {:github_cli_invalid_pull_request_response, safe_output(inspect(other))}}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:github_cli_invalid_json, Exception.message(reason)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_gh_pull_request(pull_request, configured_repository) do
    head_repository =
      get_in(pull_request, ["headRepository", "nameWithOwner"]) ||
        repository_from_owner(
          get_in(pull_request, ["headRepositoryOwner", "login"]),
          configured_repository
        )

    %{
      state: pull_request |> Map.get("state", "") |> String.downcase(),
      url: Map.get(pull_request, "url"),
      head: Map.get(pull_request, "headRefName"),
      base: Map.get(pull_request, "baseRefName"),
      head_repository: head_repository,
      source: :gh
    }
  end

  defp gh_create(executable, request, opts) do
    args = [
      "pr",
      "create",
      "--repo",
      request.repository,
      "--base",
      request.base,
      "--head",
      "#{repository_owner(request.repository)}:#{request.head}",
      "--title",
      request.title,
      "--body",
      request.body
    ]

    case run_gh(executable, args, opts) do
      {:ok, _output} -> gh_pull_requests(executable, request, opts)
      {:error, create_reason} -> retry_lookup_after_create_error(executable, request, opts, create_reason)
    end
  end

  defp retry_lookup_after_create_error(executable, request, opts, create_reason) do
    case gh_pull_requests(executable, request, opts) do
      {:ok, pull_requests} ->
        case matching_open_pull_request(pull_requests, request) do
          nil -> {:error, {:github_pull_request_create_failed, create_reason}}
          pull_request -> {:ok, pull_requests_with_created(pull_requests, pull_request)}
        end

      {:error, lookup_reason} ->
        {:error, {:github_pull_request_create_failed, create_reason, lookup_reason}}
    end
  end

  defp pull_requests_with_created(pull_requests, pull_request), do: [Map.put(pull_request, :created, true) | pull_requests]

  defp ensure_from_lookup(pull_requests, request, create) do
    case matching_open_pull_request(pull_requests, request) do
      nil ->
        case matching_closed_pull_request(pull_requests, request) do
          nil -> create_and_resolve(create, request)
          pull_request -> {:error, {:pull_request_conflict, pull_request.state, pull_request.url}}
        end

      pull_request ->
        {:ok, pull_request_result(pull_request, request)}
    end
  end

  defp create_and_resolve(create, request) do
    case create.() do
      {:ok, pull_requests} ->
        case matching_open_pull_request(pull_requests, request) do
          nil -> {:error, :github_pull_request_missing_after_create}
          pull_request -> {:ok, pull_request_result(pull_request, request)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matching_open_pull_request(pull_requests, request) do
    Enum.find(pull_requests, &(matching_pull_request?(&1, request) and &1.state == "open"))
  end

  defp matching_closed_pull_request(pull_requests, request) do
    Enum.find(pull_requests, &(matching_pull_request?(&1, request) and &1.state in ["closed", "merged"]))
  end

  defp matching_pull_request?(pull_request, request) do
    repository_identity_equal?(pull_request.head_repository, request.repository) and
      pull_request.head == request.head and pull_request.base == request.base
  end

  defp pull_request_result(pull_request, request) do
    %{
      url: pull_request.url,
      repository: request.repository,
      base: request.base,
      head: request.head,
      source: pull_request.source
    }
  end

  defp ensure_with_rest(request, token, opts) do
    with {:ok, actual_repository} <- rest_repository_identity(request.repository, token, opts),
         :ok <- validate_repository_identity(request.repository, actual_repository),
         :ok <- rest_branch_exists(request.repository, request.head, token, opts),
         {:ok, pull_requests} <- rest_pull_requests(request, token, opts) do
      ensure_from_lookup(pull_requests, request, fn -> rest_create(request, token, opts) end)
    end
  end

  defp rest_repository_identity(repository, token, opts) do
    with {:ok, %{status: 200, body: body}} <- rest_request(:get, "/repos/#{repository}", token, nil, opts),
         actual when is_binary(actual) <- map_value(body, "full_name") do
      {:ok, actual}
    else
      {:ok, response} -> {:error, github_http_error(:repository_lookup, response, token)}
      nil -> {:error, :github_repository_identity_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rest_branch_exists(repository, branch, token, opts) do
    path = "/repos/#{repository}/branches/#{encode_path_segment(branch)}"

    case rest_request(:get, path, token, nil, opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, {:remote_branch_not_found, branch}}
      {:ok, response} -> {:error, github_http_error(:branch_lookup, response, token)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rest_pull_requests(request, token, opts) do
    query =
      URI.encode_query(%{
        "state" => "all",
        "head" => "#{repository_owner(request.repository)}:#{request.head}",
        "base" => request.base,
        "per_page" => "100"
      })

    path = "/repos/#{request.repository}/pulls?#{query}"

    case rest_request(:get, path, token, nil, opts) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, &normalize_rest_pull_request/1)}

      {:ok, response} ->
        {:error, github_http_error(:pull_request_lookup, response, token)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_rest_pull_request(pull_request) do
    state =
      if map_value(pull_request, "merged_at") do
        "merged"
      else
        pull_request |> map_value("state", "") |> String.downcase()
      end

    %{
      state: state,
      url: map_value(pull_request, "html_url"),
      head: get_in_any(pull_request, ["head", "ref"]),
      base: get_in_any(pull_request, ["base", "ref"]),
      head_repository: get_in_any(pull_request, ["head", "repo", "full_name"]),
      source: :rest
    }
  end

  defp rest_create(request, token, opts) do
    body = %{
      "title" => request.title,
      "head" => request.head,
      "base" => request.base,
      "body" => request.body
    }

    case rest_request(:post, "/repos/#{request.repository}/pulls", token, body, opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        rest_pull_requests(request, token, opts)

      {:ok, %{status: 422} = response} ->
        resolve_rest_create_race(response, request, token, opts)

      {:ok, response} ->
        {:error, github_http_error(:pull_request_create, response, token)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_rest_create_race(response, request, token, opts) do
    with {:ok, pull_requests} <- rest_pull_requests(request, token, opts) do
      if matching_open_pull_request(pull_requests, request),
        do: {:ok, pull_requests},
        else: {:error, github_http_error(:pull_request_create, response, token)}
    end
  end

  defp rest_request(method, path, token, body, opts) do
    url = @api_base <> path
    timeout_ms = Keyword.get(opts, :timeout_ms, @command_timeout_ms)
    request = Keyword.get(opts, :http_request, &default_http_request/5)

    case request.(method, url, github_headers(token), body, timeout_ms) do
      {:ok, %{status: status} = response} when is_integer(status) ->
        {:ok, response}

      {:error, reason} ->
        {:error, {:github_http_request_failed, safe_output(inspect(reason), [token])}}

      other ->
        {:error, {:unexpected_github_http_result, safe_output(inspect(other), [token])}}
    end
  end

  defp default_http_request(method, url, headers, body, timeout_ms) do
    request_opts = [
      method: method,
      url: url,
      headers: headers,
      receive_timeout: timeout_ms,
      connect_options: RuntimeProxy.connect_options(url, timeout: timeout_ms)
    ]

    request_opts = if is_map(body), do: Keyword.put(request_opts, :json, body), else: request_opts

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp github_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "symphony-elixir"}
    ]
  end

  defp github_http_error(operation, response, token) do
    status = Map.get(response, :status)
    body = response |> Map.get(:body) |> inspect() |> safe_output([token])
    {:github_http_error, operation, status, body}
  end

  defp run_gh(executable, args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @command_timeout_ms)
    runner = Keyword.get(opts, :command_runner, &default_command_runner/3)

    case runner.(executable, args, timeout_ms) do
      {:ok, output} -> {:ok, IO.iodata_to_binary(output)}
      {:error, reason} -> {:error, sanitize_command_reason(reason)}
      {output, 0} -> {:ok, IO.iodata_to_binary(output)}
      {output, status} -> {:error, {:github_command_failed, args, status, safe_output(output)}}
      other -> {:error, {:unexpected_github_command_result, safe_output(inspect(other))}}
    end
  end

  defp default_command_runner(executable, args, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [
          {~c"GH_PROMPT_DISABLED", ~c"1"},
          {~c"GIT_TERMINAL_PROMPT", ~c"0"},
          {~c"NO_COLOR", ~c"1"}
        ]
      ])

    receive_command_port(port, args, timeout_ms, started_at, "")
  end

  defp receive_command_port(port, args, timeout_ms, started_at, recent_output) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    remaining_ms = max(timeout_ms - elapsed_ms, 0)

    receive do
      {^port, {:data, chunk}} ->
        receive_command_port(port, args, timeout_ms, started_at, append_recent_output(recent_output, chunk))

      {^port, {:exit_status, 0}} ->
        {:ok, recent_output}

      {^port, {:exit_status, status}} ->
        {:error, {:github_command_failed, args, status, safe_output(recent_output)}}
    after
      remaining_ms ->
        close_port(port)
        {:error, {:github_command_timeout, args, timeout_ms, safe_output(recent_output)}}
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _reason -> :ok
  end

  defp append_recent_output(current, chunk) do
    output = current <> IO.iodata_to_binary(chunk)

    if byte_size(output) <= @recent_output_bytes do
      output
    else
      binary_part(output, byte_size(output) - @recent_output_bytes, @recent_output_bytes)
    end
  end

  defp sanitize_command_reason({kind, args, value, output})
       when kind in [:github_command_failed, :github_command_timeout],
       do: {kind, args, value, safe_output(output)}

  defp sanitize_command_reason(reason), do: reason

  defp validate_identifier(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    if Regex.match?(~r/^[A-Za-z][A-Za-z0-9]*-[0-9]+$/, identifier),
      do: {:ok, identifier},
      else: {:error, {:invalid_issue_identifier, identifier}}
  end

  defp validate_identifier(_identifier), do: {:error, :missing_issue_identifier}

  defp validate_title(title) when is_binary(title) do
    title = String.trim(title)

    cond do
      title == "" -> {:error, :missing_issue_title}
      String.contains?(title, ["\n", "\r", <<0>>]) -> {:error, :invalid_issue_title}
      true -> {:ok, title}
    end
  end

  defp project_default_branch(%{default_branch: default_branch}), do: BranchName.validate(default_branch)
  defp project_default_branch(%{"default_branch" => default_branch}), do: BranchName.validate(default_branch)
  defp project_default_branch(_project), do: {:error, :missing_default_branch}

  defp project_repository(%{repository_url: repository_url}), do: parse_repository(repository_url)
  defp project_repository(%{"repository_url" => repository_url}), do: parse_repository(repository_url)
  defp project_repository(_project), do: {:error, :missing_github_repository}

  defp parse_repository(repository_url) when is_binary(repository_url) do
    repository_url = String.trim(repository_url)

    if Regex.match?(~r/^git@github\.com:/i, repository_url) do
      repository_url
      |> String.replace(~r/^git@github\.com:/i, "")
      |> repository_from_path()
    else
      repository_from_uri(URI.parse(repository_url))
    end
  end

  defp parse_repository(_repository_url), do: {:error, :missing_github_repository}

  defp repository_from_uri(%URI{scheme: scheme, host: host, path: path})
       when scheme in ["http", "https", "ssh"] and is_binary(host) and is_binary(path) do
    if String.downcase(host) == "github.com",
      do: repository_from_path(path),
      else: {:error, {:unsupported_repository_host, host}}
  end

  defp repository_from_uri(_uri), do: {:error, :unsupported_github_repository_url}

  defp repository_from_path(path) do
    parts =
      path
      |> String.trim("/")
      |> String.trim_trailing(".git")
      |> String.split("/", trim: true)

    case parts do
      [owner, repository] -> validate_repository_parts(owner, repository)
      _ -> {:error, :invalid_github_repository_path}
    end
  end

  defp validate_repository_parts(owner, repository) do
    valid? =
      Enum.all?([owner, repository], fn part ->
        part != "" and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, part)
      end)

    if valid?, do: {:ok, "#{owner}/#{repository}"}, else: {:error, :invalid_github_repository_path}
  end

  defp validate_repository_identity(expected, actual) when is_binary(actual) do
    if repository_identity_equal?(expected, actual),
      do: :ok,
      else: {:error, {:github_repository_mismatch, expected, actual}}
  end

  defp repository_identity_equal?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp repository_identity_equal?(_left, _right), do: false

  defp repository_owner(repository), do: repository |> String.split("/", parts: 2) |> List.first()

  defp repository_from_owner(owner, configured_repository) when is_binary(owner) do
    repository = configured_repository |> String.split("/", parts: 2) |> List.last()
    "#{owner}/#{repository}"
  end

  defp repository_from_owner(_owner, _configured_repository), do: nil

  defp encode_path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp github_token(opts) do
    if Keyword.has_key?(opts, :token) do
      case Keyword.get(opts, :token) do
        token when is_binary(token) and token != "" -> token
        _ -> nil
      end
    else
      Enum.find_value(@token_env_names, &non_empty_env/1)
    end
  end

  defp non_empty_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp gh_executable(opts) do
    if Keyword.has_key?(opts, :gh_executable),
      do: Keyword.get(opts, :gh_executable),
      else: System.find_executable("gh")
  end

  defp not_found_error?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?(["http 404", "not found"])
  end

  defp domain_error?(reason) do
    match?({:remote_branch_not_found, _}, reason) or
      match?({:github_repository_mismatch, _, _}, reason) or
      match?({:pull_request_conflict, _, _}, reason)
  end

  defp safe_output(output, extra_secrets \\ []) do
    output
    |> IO.iodata_to_binary()
    |> Redaction.sensitive_env_values(@token_env_names)
    |> redact_extra_secrets(extra_secrets)
    |> Redaction.bounded(@recent_output_bytes)
  end

  defp redact_extra_secrets(output, secrets) do
    Enum.reduce(secrets, output, fn
      secret, acc when is_binary(secret) and secret != "" ->
        String.replace(acc, secret, "[REDACTED]")

      _secret, acc ->
        acc
    end)
  end

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Enum.find_value(map, default, &matching_map_value(&1, key))
    end
  end

  defp map_value(_map, _key, default), do: default

  defp matching_map_value({candidate, value}, key) do
    if to_string(candidate) == key, do: value
  end

  defp get_in_any(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case map_value(current, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end
end

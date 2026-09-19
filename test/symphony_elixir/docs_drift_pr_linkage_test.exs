defmodule SymphonyElixir.DocsDriftPrLinkageTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/docs_drift_pr_linkage.sh", __DIR__)
  @workflow Path.expand("../../.github/workflows/docs-drift.yml", __DIR__)
  @no_implementation "::notice::Docs drift linkage: no implementation paths changed.\n"
  @linked "::notice::Docs drift linkage: implementation and documentation paths changed.\n"

  setup do
    root = Path.join(System.tmp_dir!(), "docs-linkage-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "--quiet"])
    write(root, "seed", "base\n")
    base = commit(root, "2026-01-01T00:00:00Z")
    %{root: root, base: base}
  end

  test "implementation-only changes emit one complete sorted warning", context do
    paths = ["lib/z.ex", "config/runtime.exs", "lib/a.ex"]
    head = change(context.root, paths)
    {stdout, status} = run(context, head)

    assert status == 0
    assert stdout == warning(paths)
    assert length(Regex.scan(~r/^::warning::/m, stdout)) == 1
    assert Enum.all?(paths, &String.contains?(stdout, &1))
  end

  test "one annotation includes every implementation file without truncation", context do
    paths = for index <- 1..100, do: "lib/nested/file_#{index}.ex"
    head = change(context.root, paths)
    {stdout, status} = run(context, head)

    assert status == 0
    assert stdout == warning(paths)
    assert length(Regex.scan(~r/^::warning::/m, stdout)) == 1
    assert Enum.all?(paths, &String.contains?(stdout, &1))
  end

  for path <- ["docs/guide.md", "README.md", "AGENTS.md"] do
    test "implementation plus #{path} satisfies linkage", context do
      head = change(context.root, ["lib/sample.ex", unquote(path)])
      {stdout, status} = run(context, head)
      assert status == 0
      assert stdout == @linked
    end
  end

  test "documentation-only changes produce a notice", context do
    head = change(context.root, ["docs/guide.md", "README.md", "AGENTS.md"])
    {stdout, status} = run(context, head)
    assert status == 0
    assert stdout == @no_implementation
  end

  test "neutral paths neither trigger nor satisfy linkage", context do
    neutral = ["scripts/check.sh", "test/sample.exs", ".github/workflows/example.yml", "mix.exs"]
    head = change(context.root, neutral)
    {stdout, status} = run(context, head)
    assert status == 0
    assert stdout == @no_implementation

    head = change(context.root, ["lib/sample.ex"])
    {stdout, status} = run(context, head)
    assert status == 0
    assert stdout == warning(["lib/sample.ex"])
  end

  test "empty diff produces a notice", context do
    {stdout, status} = run(context, context.base)
    assert status == 0
    assert stdout == @no_implementation
  end

  for {label, body, reason} <- [
        {"adjacent reason", "#### Docs Drift Exemption\nReason: Internal refactor.\n", "Internal refactor."},
        {"blank lines", "#### Docs Drift Exemption\n\n \t\nReason: No behavior change.\n", "No behavior change."},
        {"CRLF", "#### Docs Drift Exemption\r\n\r\nReason: Internal refactor.\r\n", "Internal refactor."},
        {"annotation escaping", "#### Docs Drift Exemption\nReason: 100% reviewed.\n", "100%25 reviewed."},
        {"after fence", "```markdown\nexample\n```\n#### Docs Drift Exemption\nReason: Reviewed.\n", "Reviewed."}
      ] do
    test "valid exemption with #{label} emits only a notice carrying its reason", context do
      head = change(context.root, ["lib/sample.ex"])
      {stdout, status} = run(context, head, unquote(body))
      assert status == 0
      assert stdout == "::notice::Docs drift linkage exemption: #{unquote(reason)}\n"
    end
  end

  for {label, body} <- [
        {"empty body", ""},
        {"heading without reason", "#### Docs Drift Exemption\n"},
        {"empty reason", "#### Docs Drift Exemption\nReason:\n"},
        {"whitespace reason", "#### Docs Drift Exemption\nReason: \t \n"},
        {"wrong heading level", "### Docs Drift Exemption\nReason: Refactor.\n"},
        {"trailing heading spaces", "#### Docs Drift Exemption  \nReason: Refactor.\n"},
        {"leading heading spaces", " #### Docs Drift Exemption\nReason: Refactor.\n"},
        {"intervening content", "#### Docs Drift Exemption\nNot a reason.\nReason: Refactor.\n"},
        {"missing reason space", "#### Docs Drift Exemption\nReason:Refactor.\n"},
        {"backtick fence", "```markdown\n#### Docs Drift Exemption\nReason: Refactor.\n```\n"},
        {"tilde fence", "~~~\n#### Docs Drift Exemption\nReason: Refactor.\n~~~\n"},
        {"long fence", "````markdown\n```\n#### Docs Drift Exemption\nReason: Refactor.\n````\n"},
        {"fenced reason", "#### Docs Drift Exemption\n```\nReason: Refactor.\n```\n"}
      ] do
    test "malformed exemption: #{label} preserves the warning", context do
      head = change(context.root, ["lib/sample.ex"])
      {stdout, status} = run(context, head, unquote(body))
      assert status == 0
      assert stdout == warning(["lib/sample.ex"])
    end
  end

  test "deleted and renamed implementation paths count", context do
    change(context.root, ["lib/deleted.ex", "lib/before.ex"])
    base = git!(context.root, ["rev-parse", "HEAD"])
    File.rm!(Path.join(context.root, "lib/deleted.ex"))
    File.rename!(Path.join(context.root, "lib/before.ex"), Path.join(context.root, "lib/after.ex"))
    head = commit(context.root, "2026-01-03T00:00:00Z")
    {stdout, status} = run(%{context | base: base}, head)
    assert status == 0
    assert stdout == warning(["lib/deleted.ex", "lib/after.ex"])
  end

  test "triple-dot diff excludes changes made only on the base branch", context do
    head = change(context.root, ["lib/sample.ex"])
    git!(context.root, ["checkout", "--quiet", "--detach", context.base])
    base = change(context.root, ["docs/base-only.md"])
    {stdout, status} = run(%{context | base: base}, head)
    assert status == 0
    assert stdout == warning(["lib/sample.ex"])
  end

  for {label, args, message} <- [
        {"no flags", [], "Missing required flag --base."},
        {"missing base", ["--head", "HEAD"], "Missing required flag --base."},
        {"missing head", ["--base", "HEAD"], "Missing required flag --head."},
        {"base without value", ["--base"], "Missing value for --base."},
        {"head without value", ["--base", "HEAD", "--head"], "Missing value for --head."},
        {"flag as value", ["--base", "--head", "HEAD"], "Missing value for --base."},
        {"empty SHA", ["--base", "", "--head", "HEAD"], "Missing value for --base."},
        {"unresolvable base", ["--base", "missing", "--head", "HEAD"], "Cannot resolve --base to a local commit."},
        {"unresolvable head", ["--base", "HEAD", "--head", "missing"], "Cannot resolve --head to a local commit."}
      ] do
    test "input error: #{label} exits 2 with one error annotation and stderr explanation", context do
      # Capture stderr separately so the assertion covers exact stdout as well.
      {stdout, status} =
        System.cmd("bash", ["-c", ~S(exec bash "$@" 2>error.txt), "linkage", @script | unquote(args)], cd: context.root)

      assert status == 2
      assert stdout == "::error::#{unquote(message)}\n"
      assert length(Regex.scan(~r/^::error::/m, stdout)) == 1
      assert File.read!(Path.join(context.root, "error.txt")) == "docs-drift: #{unquote(message)}\n"
    end
  end

  test "workflow runs the independent advisory check with safe body transport" do
    workflow = File.read!(@workflow)
    assert workflow =~ "name: docs-drift\n"
    assert workflow =~ "pull_request:\n    types: [opened, reopened, synchronize, edited, ready_for_review]"
    assert workflow =~ "permissions:\n  contents: read\n"
    assert workflow =~ "group: docs-drift-${{ github.event.pull_request.number }}"
    assert workflow =~ "cancel-in-progress: true"
    assert workflow =~ "runs-on: ubuntu-latest"
    assert workflow =~ "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7"
    assert workflow =~ "fetch-depth: 0"
    assert workflow =~ "continue-on-error: true"
    assert workflow =~ "BASE_SHA: ${{ github.event.pull_request.base.sha }}"
    assert workflow =~ "HEAD_SHA: ${{ github.event.pull_request.head.sha }}"
    assert workflow =~ "PR_BODY: ${{ github.event.pull_request.body }}"
    assert workflow =~ "set -euo pipefail"
    assert workflow =~ ~S(printf '%s' "$PR_BODY" > "$body_file")
    assert workflow =~ ~S(scripts/docs_drift_pr_linkage.sh --base "$BASE_SHA" --head "$HEAD_SHA" --body "$body_file")
    [_, run] = String.split(workflow, "        run: |", parts: 2)
    assert Regex.scan(~r/\$\{\{/, run) == []
  end

  defp run(context, head, body \\ nil) do
    args = [@script, "--base", context.base, "--head", head]

    args =
      if is_binary(body) do
        write(context.root, "body.md", body)
        args ++ ["--body", Path.join(context.root, "body.md")]
      else
        args
      end

    System.cmd("bash", args, cd: context.root)
  end

  defp warning(paths) do
    "::warning::Docs drift linkage: implementation changed without documentation: #{paths |> Enum.sort() |> Enum.join(" ")}\n"
  end

  defp change(root, paths) do
    Enum.each(paths, &write(root, &1, "changed #{&1}\n"))
    commit(root, "2026-01-02T00:00:00Z")
  end

  defp write(root, path, content) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit(root, date) do
    git!(root, ["add", "."])

    git!(root, ["commit", "--quiet", "-m", "fixture"], env: [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date}])

    git!(root, ["rev-parse", "HEAD"])
  end

  defp git!(root, args, opts \\ []) do
    config = [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null"
    ]

    {output, status} = System.cmd("git", config ++ args, Keyword.merge([cd: root, stderr_to_stdout: true], opts))
    assert status == 0, output
    String.trim(output)
  end
end

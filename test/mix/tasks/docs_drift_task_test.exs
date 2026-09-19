defmodule Mix.Tasks.Docs.DriftTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Docs.Drift
  import ExUnit.CaptureIO

  setup do
    original = File.cwd!()
    root = Path.join(original, "_build/docs-drift-test-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    File.cd!(root)

    on_exit(fn ->
      File.cd!(original)
      File.rm_rf!(root)
    end)

    git!(["init", "--quiet"])

    write("docs/README.md", """
    ## L3 — Feature Designs
    | Document | Purpose |
    | --- | --- |
    | [future.md](future.md) | ignored |
    ## L4 — Normative Contracts
    A prose link [ignored.md](ignored.md) is not a table row.
    | Document | Purpose |
    | --- | --- |
    | [contract.md](contract.md) | contract |
    ## L5 — Operational Guides
    | Document | Purpose |
    | --- | --- |
    | [guide.md](guide.md#usage) | guide |
    ## Other
    | [ignored.md](ignored.md) | ignored |
    """)

    write("docs/contract.md", doc("SymphonyElixir.Sample"))
    write("docs/guide.md", doc("compose.yaml"))
    write("docs/documentation-alignment.md", "governance matrix\n")
    write("docs/drift-allowlist.yml", "entries: []\n")
    write("lib/sample.ex", "defmodule SymphonyElixir.Sample do\nend\n")
    write("compose.yaml", "services: {}\n")
    commit("2026-01-01T00:00:00Z")
    :ok
  end

  test "registry tables select L4/L5 plus alignment, excluding L3 and non-table links" do
    report = report()
    assert Enum.map(report["freshness"], & &1["document"]) == ~w(docs/contract.md docs/documentation-alignment.md docs/guide.md)
    assert report["summary"] == %{"documents" => 3, "references" => 0, "exempt" => 0, "stale" => 0, "skipped" => 1, "errors" => 0}
  end

  test "exact modules, nested declarations, explicit paths and runtime identifiers are valid candidates" do
    write("lib/config.ex", """
    defmodule SymphonyElixir.Config do
      def enabled, do: System.get_env("SERVICE_TOKEN")
      defmodule Nested do
        def value(arg \\\\ nil), do: arg
      end
    end
    defmodule Mix.Tasks.Example do
    end
    """)

    write("config/runtime.exs", "name = \"SYMPHONY_SAMPLE\"\n")
    write("mix.exs", "# fixture\n")

    tokens =
      ~w(SymphonyElixir.Sample SymphonyElixir.Config.Nested Mix.Tasks.Example lib/sample.ex:12 docs/guide.md#usage mix.exs SYMPHONY_SAMPLE SERVICE_TOKEN SymphonyElixir.Config.enabled SymphonyElixir.Config.enabled/0 SymphonyElixir.Config.enabled\(\) SymphonyElixir.Config.Nested.value/0)

    write("docs/contract.md", doc("SymphonyElixir.Sample", Enum.map_join(tokens, " ", &"`#{&1}`")))
    references = report()["references"]
    assert Enum.map(references, & &1["token"]) == tokens
    assert Enum.map(references, & &1["status"]) == List.duplicate("valid", length(tokens))
    assert Enum.frequencies_by(references, & &1["kind"]) == %{"module" => 3, "path" => 3, "config" => 6}
  end

  test "commands, flags, URLs, statuses, shorthand, glob paths and fenced examples are ignored" do
    body = """
    `mix docs.check` `--format json` `https://example.org/lib/no.ex`
    `Ready` `IN_PROGRESS` `MUST` `Config` `SymphonyElixir.Sample.run()`
    `lib/*.ex` `docs/*-design.md` `workflow.yml` `$SYMPHONY_GHOST` `SYMPHONY_X=true`
    ```elixir
    `SymphonyElixir.Fenced`
    ```
    ~~~text
    `lib/fenced.ex`
    ~~~
    ``SymphonyElixir.Sample``
    """

    write("docs/contract.md", doc("SymphonyElixir.Sample", body))
    assert [%{"token" => "SymphonyElixir.Sample", "status" => "valid"}] = report()["references"]
  end

  test "invalid references expose exact stable fields and raise Mix.Error for a non-zero CLI exit" do
    write("lib/config.ex", "defmodule SymphonyElixir.Config do\n def enabled_extra, do: :ok\nend\n")
    write("config/runtime.exs", "name = \"SYMPHONY_GHOST_SUFFIX\"\n")
    write("docs/contract.md", doc("SymphonyElixir.Sample", "`SymphonyElixir.Missing`\n`lib/missing.ex`\n`SYMPHONY_GHOST`\n`SymphonyElixir.Config.enabled/0`"))
    references = report(error: true)["references"]
    assert Enum.map(references, & &1["kind"]) == ~w(module path config config)
    assert Enum.map(references, & &1["line"]) == [4, 5, 6, 7]

    Enum.each(references, fn record ->
      assert Enum.sort(Map.keys(record)) == ~w(document kind line reason status token)
      assert record["document"] == "docs/contract.md"
      assert record["status"] == "error"
      assert is_binary(record["reason"]) and record["reason"] != ""
    end)
  end

  test "allowlist exempts an exact current candidate with its reviewed reason" do
    write("docs/contract.md", doc("SymphonyElixir.Sample", "`SymphonyElixir.External`"))
    write("docs/drift-allowlist.yml", Jason.encode!(%{entries: [entry()]}))
    assert [%{"status" => "exempt", "reason" => "test-only declaration"}] = report()["references"]
  end

  test "allowlist rejects malformed entries, extra keys, duplicates, stale entries and empty reasons" do
    write("docs/contract.md", doc("SymphonyElixir.Sample", "`SymphonyElixir.External`"))

    for {entries, reason} <- [
          {["bad"], "entry requires exactly"},
          {[Map.delete(entry(), :token)], "entry requires exactly"},
          {[Map.put(entry(), :extra, true)], "entry requires exactly"},
          {[Map.put(entry(), :reason, "  ")], "entry requires exactly"},
          {[Map.put(entry(), :reason, 42)], "entry requires exactly"},
          {[entry(), entry()], "duplicate document + token identity"},
          {[Map.put(entry(), :token, "SymphonyElixir.Gone")], "entry no longer matches"}
        ] do
      write("docs/drift-allowlist.yml", Jason.encode!(%{entries: entries}))
      assert [error] = report(error: true)["allowlist_errors"]
      assert String.starts_with?(error["reason"], reason)
    end
  end

  test "allowlist rejects malformed YAML and invalid top-level shape" do
    for yaml <- [
          "entries: [",
          "entries: wrong",
          "other: []",
          "entries: []\nextra: true",
          "entries: []\n---\nentries: []",
          "entries: []\nentries: []",
          "entries:\n  - document: docs/contract.md\n    token: first\n    token: second\n    reason: reviewed"
        ] do
      write("docs/drift-allowlist.yml", yaml)
      assert [_error] = report(error: true)["allowlist_errors"]
    end
  end

  test "module and path owners resolve, and missing owner explicitly skips with a reason" do
    assert [module, skip, path] = report()["freshness"]
    assert module["owner"] == "SymphonyElixir.Sample"
    assert path["owner"] == "compose.yaml"
    assert module["doc_last_modified"] == "2026-01-01T00:00:00Z"
    assert module["owner_last_touched"] == "2026-01-01T00:00:00Z"
    assert module["status"] == "fresh"
    assert path["status"] == "fresh"
    assert skip["status"] == "SKIP"
    assert skip["reason"] == "no single owner declared in frontmatter"
    assert skip["owner"] == nil
  end

  test "invalid module and repository-path owners are errors" do
    for owner <- ["SymphonyElixir.Missing", "lib/missing.ex", "../outside", "/absolute"] do
      write("docs/contract.md", doc(owner))
      assert [record | _] = report(error: true)["freshness"]
      assert record["status"] == "error"
      assert record["reason"] == "invalid owner: #{owner}"
    end
  end

  test "exact threshold is fresh, one second beyond is stale and never fails" do
    write("lib/sample.ex", "defmodule SymphonyElixir.Sample do\n # boundary\nend\n")
    commit("2026-01-31T00:00:00Z")
    assert [boundary | _] = report()["freshness"]
    assert boundary["delta_days"] == 30.0
    assert boundary["status"] == "fresh"

    write("lib/sample.ex", "defmodule SymphonyElixir.Sample do\n # beyond\nend\n")
    commit("2026-01-31T00:00:01Z")
    assert [beyond | _] = report()["freshness"]
    assert beyond["delta_days"] == 30 + 1 / 86_400
    assert beyond["status"] == "stale"
    assert report()["summary"]["errors"] == 0
    assert [override | _] = report(args: ["--freshness-days", "31"])["freshness"]
    assert override["status"] == "fresh"
  end

  test "first document commit and code/docs changed in the same commit are fresh" do
    write("docs/contract.md", doc("SymphonyElixir.Sample", "updated"))
    write("lib/sample.ex", "defmodule SymphonyElixir.Sample do\n # changed\nend\n")
    commit("2026-04-01T00:00:00Z")
    assert [record | _] = report(args: ["--freshness-days", "0"])["freshness"]
    assert record["doc_last_modified"] == "2026-04-01T00:00:00Z"
    assert record["owner_last_touched"] == "2026-04-01T00:00:00Z"
    assert record["delta_days"] == 0.0
    assert record["status"] == "fresh"
  end

  test "renamed documents and module files use their last touching commit" do
    git!(["mv", "docs/contract.md", "docs/renamed.md"])
    write("docs/README.md", String.replace(File.read!("docs/README.md"), "contract.md", "renamed.md"))
    git!(["mv", "lib/sample.ex", "lib/renamed.ex"])
    commit("2026-03-01T00:00:00Z")
    record = Enum.find(report()["freshness"], &(&1["document"] == "docs/renamed.md"))
    assert record["doc_last_modified"] == "2026-03-01T00:00:00Z"
    assert record["owner_last_touched"] == "2026-03-01T00:00:00Z"
    assert record["status"] == "fresh"
  end

  test "an untracked document or owner has missing history and fails explicitly" do
    write("docs/new.md", doc("SymphonyElixir.Sample"))
    write("docs/README.md", String.replace(File.read!("docs/README.md"), "contract.md", "new.md"))
    record = Enum.find(report(error: true)["freshness"], &(&1["document"] == "docs/new.md"))
    assert record["reason"] == "missing Git history: docs/new.md"

    write("lib/new.ex", "defmodule SymphonyElixir.New do\nend\n")
    write("docs/guide.md", doc("SymphonyElixir.New"))
    record = Enum.find(report(error: true)["freshness"], &(&1["document"] == "docs/guide.md"))
    assert record["reason"] == "missing Git history: lib/new.ex"
  end

  test "JSON schema and human freshness fields stay aligned" do
    report = report()
    assert Enum.sort(Map.keys(report)) == ~w(allowlist_errors freshness references summary)

    Enum.each(report["freshness"], fn record ->
      assert Enum.sort(Map.keys(record)) == ~w(delta_days doc_last_modified document owner owner_last_touched reason status)
    end)

    output = capture_io(fn -> Drift.run([]) end)
    assert output =~ "fresh document=docs/contract.md owner=SymphonyElixir.Sample doc_last_modified=2026-01-01T00:00:00Z owner_last_touched=2026-01-01T00:00:00Z delta_days=0.0 status=fresh"
    assert output =~ "SKIP document=docs/documentation-alignment.md"
    assert output =~ "docs.drift: 3 documents, 0 references, 0 exempt, 0 stale, 1 skipped, 0 errors"
  end

  test "rejects invalid CLI values" do
    for args <- [["--freshness-days", "-1"], ["--freshness-days", "bad"], ["--format", "xml"], ["--unknown"], ["extra"]] do
      assert_raise Mix.Error, ~r/Usage: mix docs.drift/, fn -> Drift.run(args) end
    end
  end

  defp report(options \\ []) do
    capture_io(fn ->
      args = ["--format", "json"] ++ Keyword.get(options, :args, [])

      if options[:error] do
        assert_failure(args)
      else
        Drift.run(args)
      end
    end)
    |> Jason.decode!()
  end

  defp assert_failure(args) do
    assert_raise Mix.Error, ~r/docs.drift failed/, fn -> Drift.run(args) end
  end

  defp doc(owner, body \\ ""), do: "---\nowner: #{owner}\n---\n#{body}\n"
  defp entry, do: %{document: "docs/contract.md", token: "SymphonyElixir.External", reason: "test-only declaration"}

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit(timestamp) do
    git!(["add", "."])

    git!(["-c", "user.name=Docs Drift Test", "-c", "user.email=docs-drift@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"],
      env: [{"GIT_AUTHOR_DATE", timestamp}, {"GIT_COMMITTER_DATE", timestamp}]
    )
  end

  defp git!(args, options \\ []) do
    assert {_, 0} = System.cmd("git", args, Keyword.put(options, :stderr_to_stdout, true))
  end
end

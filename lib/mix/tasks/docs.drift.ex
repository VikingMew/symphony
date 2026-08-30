defmodule Mix.Tasks.Docs.Drift do
  use Mix.Task

  @moduledoc "Checks documentation references and owner freshness."
  @shortdoc "Checks documentation drift"

  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: [format: :string, freshness_days: :integer])
    days = opts[:freshness_days] || 30
    docs = target_documents()
    findings = Enum.flat_map(docs, &scan_document/1)
    Enum.each(findings, &emit(&1, opts[:format]))
    freshness = Enum.map(docs, &freshness(&1, days))
    if opts[:format] == "json", do: Mix.shell().info(Jason.encode!(freshness))
    if Enum.any?(findings, &(&1.status == "invalid")), do: Mix.raise("docs.drift found invalid references")
    :ok
  end

  defp target_documents do
    index = File.read!("docs/README.md")
    paths = Regex.scan(~r/\]\(([^)]+\.md)\)/, index, capture: :all_but_first) |> List.flatten()

    paths =
      Enum.filter(paths, fn p ->
        String.starts_with?(p, "spec-") or
          p in [
            "spec.md",
            "logging.md",
            "token_accounting.md",
            "persistence_and_auth.md",
            "pull-request-body.md",
            "test_database_isolation.md",
            "user-guide.zh-CN.md",
            "compose.md",
            "deployment.md",
            "execution-worker-operations.md"
          ]
      end)

    (Enum.map(paths, &Path.join("docs", &1)) ++ ["docs/documentation-alignment.md"]) |> Enum.uniq() |> Enum.filter(&File.exists?/1)
  end

  defp scan_document(path) do
    content = File.read!(path)
    modules = Path.wildcard("lib/**/*.ex") |> Enum.map(&File.read!/1) |> Enum.join("\n")
    lines = String.split(content, ~r/\r?\n/)

    Enum.with_index(lines, 1)
    |> Enum.flat_map(fn {line, n} ->
      Regex.scan(~r/`([^`]+)`/, line, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(fn token ->
        cond do
          Regex.match?(~r/^(SymphonyElixir|Mix\.Tasks)\.[A-Z]\w*(?:\.[A-Z]\w*)*$/, token) ->
            [%{kind: "module", document: path, line: n, token: token, reason: "module declaration", status: if(String.contains?(modules, "defmodule " <> token), do: "valid", else: "invalid")}]

          Regex.match?(~r/^(lib|config|docs|test|\.github)\//, token) ->
            clean = token |> String.split(~r/[:#]/) |> hd()
            [%{kind: "path", document: path, line: n, token: token, reason: "repository path", status: if(File.exists?(clean), do: "valid", else: "invalid")}]

          true ->
            []
        end
      end)
    end)
  end

  defp freshness(path, days) do
    owner = owner(path)
    doc_ts = git_time(path)
    owner_ts = if owner, do: git_time(owner)

    status =
      cond do
        is_nil(owner) -> "SKIP"
        is_nil(doc_ts) or is_nil(owner_ts) -> "SKIP"
        owner_ts > doc_ts and DateTime.diff(owner_ts, doc_ts, :day) > days -> "stale"
        true -> "fresh"
      end

    %{
      document: path,
      owner: owner || "",
      doc_last_modified: iso(doc_ts),
      owner_last_touched: iso(owner_ts),
      delta_days: if(doc_ts && owner_ts, do: DateTime.diff(owner_ts, doc_ts, :day), else: nil),
      status: status
    }
  end

  defp owner(path) do
    case Regex.run(~r/^owner:\s*(.+)$/m, File.read!(path)) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp git_time(path) do
    case System.cmd("git", ["log", "-1", "--format=%cI", "--", path], stderr_to_stdout: true) do
      {out, 0} ->
        case DateTime.from_iso8601(String.trim(out)) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp iso(nil), do: nil
  defp iso(dt), do: DateTime.to_iso8601(dt)
  defp emit(f, "json"), do: :ok
  defp emit(f, _), do: Mix.shell().info("#{f.kind} #{f.document}:#{f.line} #{f.token} #{f.reason} (#{f.status})")
end

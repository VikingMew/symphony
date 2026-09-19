defmodule Mix.Tasks.Docs.Drift do
  use Mix.Task

  @moduledoc "Checks registered current-document references and reports owner Git-history freshness."
  @shortdoc "Checks documentation drift"
  @allowlist "docs/drift-allowlist.yml"
  @module ~r/^(?:SymphonyElixir|Mix\.Tasks)(?:\.[A-Z][A-Za-z0-9_]*)+$/
  @config ~r/^(SymphonyElixir\.Config(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][a-zA-Z0-9_]*[!?]?)(?:\/(\d+)|\(\))?$/
  @path ~r/^(?:lib|config|docs|\.github|test|scripts)\/[\w.\/-]*(?::\d+(?::\d+)?|#[-\w.]+)?$/
  @root_files ~w(README.md AGENTS.md mix.exs mix.lock compose.yaml Dockerfile Makefile mise.toml .formatter.exs .credo.exs .gitignore)

  @impl Mix.Task
  def run(args) do
    options = options!(args)
    sources = sources()
    anchors = anchors(sources)
    documents = documents()
    candidates = Enum.flat_map(documents, &candidates(&1, sources))
    {exemptions, allowlist_errors} = allowlist(candidates)
    references = Enum.map(candidates, &reference(&1, sources, anchors, exemptions))
    freshness = Enum.map(documents, &freshness(&1, anchors, options[:freshness_days]))

    summary = %{
      documents: length(documents),
      references: length(references),
      exempt: Enum.count(references, &(&1.status == "exempt")),
      stale: Enum.count(freshness, &(&1.status == "stale")),
      skipped: Enum.count(freshness, &(&1.status == "SKIP")),
      errors: length(allowlist_errors) + Enum.count(references ++ freshness, &(&1.status == "error"))
    }

    report = %{references: references, freshness: freshness, allowlist_errors: allowlist_errors, summary: summary}
    print_report(report, options[:format])
    if summary.errors > 0, do: Mix.raise("docs.drift failed with #{summary.errors} error(s)")
  end

  defp options!(args) do
    {options, rest, invalid} = OptionParser.parse(args, strict: [freshness_days: :integer, format: :string])
    options = Keyword.merge([freshness_days: 30, format: "human"], options)

    if rest != [] or invalid != [] or options[:freshness_days] < 0 or options[:format] not in ["human", "json"] do
      Mix.raise("Usage: mix docs.drift [--freshness-days N] [--format human|json] (N >= 0)")
    end

    options
  end

  defp documents do
    {_, paths} =
      "docs/README.md"
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce({false, []}, fn line, {active, paths} ->
        cond do
          Regex.match?(~r/^##\s+L[45]\b/, line) -> {true, paths}
          Regex.match?(~r/^\#{1,2}\s/, line) -> {false, paths}
          active and String.starts_with?(String.trim_leading(line), "|") -> {active, paths ++ registry_paths(line)}
          true -> {active, paths}
        end
      end)

    Enum.sort(Enum.uniq(["docs/documentation-alignment.md" | paths]))
  end

  defp registry_paths(line) do
    for [_, path] <- Regex.scan(~r/\[[^\]]+\]\(([^)#]+\.md)(?:#[^)]*)?\)/, line) do
      Path.join("docs", path) |> Path.expand() |> Path.relative_to(File.cwd!())
    end
  end

  defp sources do
    (Path.wildcard("lib/**/*.{ex,exs}") ++ Path.wildcard("config/**/*.{ex,exs}"))
    |> Map.new(&{&1, File.read!(&1)})
  end

  defp anchors(sources) do
    sources
    |> Enum.filter(fn {path, _} -> String.starts_with?(path, "lib/") end)
    |> Enum.reduce(%{modules: %{}, configs: MapSet.new()}, fn {path, source}, acc ->
      collect_modules(Code.string_to_quoted!(source), nil, path, acc)
    end)
  end

  defp collect_modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent, path, acc) do
    name = Enum.map_join(parts, ".", &Atom.to_string/1)
    name = if parent && hd(parts) not in [:SymphonyElixir, :Mix], do: parent <> "." <> name, else: name
    collect_modules(body, name, path, %{acc | modules: Map.put(acc.modules, name, path)})
  end

  defp collect_modules({:def, _, [head | _body]}, parent, _path, acc) do
    head =
      case head do
        {:when, _, [call | _guards]} -> call
        call -> call
      end

    {name, _, args} = head
    args = if is_list(args), do: args, else: []
    identifier = "#{parent}.#{name}"
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))

    configs =
      Enum.reduce((length(args) - defaults)..length(args), acc.configs, fn arity, set ->
        MapSet.put(set, "#{identifier}/#{arity}")
      end)

    %{acc | configs: MapSet.put(configs, identifier)}
  end

  defp collect_modules(ast, parent, path, acc) when is_tuple(ast), do: collect_modules(Tuple.to_list(ast), parent, path, acc)

  defp collect_modules(ast, parent, path, acc) when is_list(ast),
    do: Enum.reduce(ast, acc, &collect_modules(&1, parent, path, &2))

  defp collect_modules(_ast, _parent, _path, acc), do: acc

  defp candidates(document, sources) do
    # Fenced examples are not inline references. Keep line offsets intact.
    {_, records} =
      document
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({nil, []}, fn {line, number}, {fence, records} ->
        case Regex.run(~r/^\s*(`{3,}|~{3,})/, line) do
          [_, delimiter] ->
            next = fence_state(fence, delimiter)
            {next, records}

          nil when is_nil(fence) ->
            {nil, records ++ inline_references(line, document, number, sources)}

          nil ->
            {fence, records}
        end
      end)

    records
  end

  defp inline_references(line, document, number, sources) do
    for [_, _, token] <- Regex.scan(~r/(?<!`)(`+)(?!`)(.*?)\1(?!`)/, line),
        kind = candidate_kind(token, sources),
        kind != nil do
      %{kind: kind, document: document, line: number, token: token}
    end
  end

  defp fence_state(nil, delimiter), do: delimiter

  defp fence_state(fence, delimiter) do
    if String.first(fence) == String.first(delimiter) and byte_size(delimiter) >= byte_size(fence), do: nil, else: fence
  end

  defp candidate_kind(token, sources) do
    cond do
      Regex.match?(@module, token) -> "module"
      Regex.match?(@config, token) -> "config"
      Regex.match?(@path, token) or normalize_path(token) in @root_files -> "path"
      Regex.match?(~r/^SYMPHONY_[A-Z0-9_]+$/, token) -> "config"
      environment_name?(token, sources) -> "config"
      true -> nil
    end
  end

  defp environment_name?(token, sources) do
    Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, token) and
      Enum.any?(sources, fn {_path, source} ->
        Regex.match?(~r/System\.(?:get_env|fetch_env!?)\(\s*"#{Regex.escape(token)}"/, source)
      end)
  end

  defp reference(record, sources, anchors, exemptions) do
    reason = reference_error(record, sources, anchors)

    case {Map.get(exemptions, {record.document, record.token}), reason} do
      {nil, nil} -> Map.merge(record, %{status: "valid", reason: nil})
      {nil, reason} -> Map.merge(record, %{status: "error", reason: reason})
      {exemption, _} -> Map.merge(record, %{status: "exempt", reason: exemption})
    end
  end

  defp reference_error(%{kind: "module", token: token}, _sources, anchors) do
    if not Map.has_key?(anchors.modules, token), do: "no exact defmodule declaration under lib/"
  end

  defp reference_error(%{kind: "path", token: token}, _sources, _anchors) do
    path = normalize_path(token)
    if not repository_path?(path), do: "repository path does not exist"
  end

  defp reference_error(%{kind: "config", token: token}, sources, anchors) do
    identifier = String.replace_suffix(token, "()", "/0")
    pattern = ~r/(?<![\w.])#{Regex.escape(identifier)}(?![\w!?])/u

    if not MapSet.member?(anchors.configs, identifier) and
         not Enum.any?(sources, fn {_path, source} -> Regex.match?(pattern, source) end),
       do: "exact config identifier does not occur under lib/ or config/"
  end

  defp normalize_path(token), do: Regex.replace(~r/(?::\d+(?::\d+)?|#[-\w.]+)$/, token, "")

  defp allowlist(candidates) do
    case YamlElixir.read_all_from_file(@allowlist, maps_as_keywords: true) do
      {:ok, [[{"entries", entries}]]} when is_list(entries) ->
        identities = MapSet.new(candidates, &{&1.document, &1.token})
        Enum.reduce(entries, {%{}, []}, &allowlist_entry(&1, &2, identities))

      {:ok, _} ->
        {%{}, [allowlist_error(nil, nil, "expected only an entries list")]}

      {:error, error} ->
        {%{}, [allowlist_error(nil, nil, "invalid YAML: #{inspect(error)}")]}
    end
  end

  defp allowlist_entry(entry, {exemptions, errors}, identities) do
    if valid_entry?(entry) do
      entry = Map.new(entry)
      identity = {entry["document"], entry["token"]}

      reason =
        cond do
          Map.has_key?(exemptions, identity) -> "duplicate document + token identity"
          not MapSet.member?(identities, identity) -> "entry no longer matches a current candidate"
          true -> nil
        end

      errors = if reason, do: errors ++ [allowlist_error(elem(identity, 0), elem(identity, 1), reason)], else: errors
      {Map.put(exemptions, identity, entry["reason"]), errors}
    else
      {exemptions, errors ++ [allowlist_error(nil, nil, "entry requires exactly non-empty document, token, reason strings")]}
    end
  end

  defp valid_entry?(entry) when is_list(entry) do
    Enum.all?(entry, fn
      {key, value} when is_binary(key) and is_binary(value) -> String.trim(value) != ""
      _ -> false
    end) and Enum.sort(Enum.map(entry, &elem(&1, 0))) == ~w(document reason token)
  end

  defp valid_entry?(_entry), do: false
  defp allowlist_error(document, token, reason), do: %{document: document, token: token, reason: reason}

  defp freshness(document, anchors, threshold) do
    owner = owner(document)

    record = %{
      document: document,
      owner: owner,
      doc_last_modified: nil,
      owner_last_touched: nil,
      delta_days: nil,
      status: "SKIP",
      reason: "no single owner declared in frontmatter"
    }

    if owner do
      with {:ok, path} <- owner_path(owner, anchors),
           {:ok, doc_time} <- last_touched(document),
           {:ok, owner_time} <- last_touched(path) do
        delta = DateTime.diff(owner_time, doc_time, :second) / 86_400

        %{
          record
          | doc_last_modified: DateTime.to_iso8601(doc_time),
            owner_last_touched: DateTime.to_iso8601(owner_time),
            delta_days: delta,
            status: if(delta > threshold, do: "stale", else: "fresh"),
            reason: nil
        }
      else
        {:error, reason} -> %{record | status: "error", reason: reason}
      end
    else
      record
    end
  end

  defp owner(document) do
    case String.split(File.read!(document), ~r/\r?\n/) do
      ["---" | lines] ->
        lines
        |> Enum.take_while(&(&1 != "---"))
        |> Enum.find_value(&owner_value/1)

      _ ->
        nil
    end
  end

  defp owner_value(line) do
    case Regex.run(~r/^owner:\s*(\S.*?)\s*$/, line) do
      [_, value] -> value |> String.trim("\"") |> String.trim("'")
      nil -> nil
    end
  end

  defp owner_path(owner, anchors) do
    case Map.fetch(anchors.modules, owner) do
      {:ok, path} -> {:ok, path}
      :error -> if repository_path?(owner), do: {:ok, owner}, else: {:error, "invalid owner: #{owner}"}
    end
  end

  defp repository_path?(path) do
    Path.type(path) == :relative and ".." not in Path.split(path) and File.exists?(path)
  end

  defp last_touched(path) do
    follow = if File.regular?(path), do: ["--follow"], else: []

    case System.cmd("git", ["log" | follow] ++ ["-1", "--format=%ct", "--", path], stderr_to_stdout: true) do
      {"", 0} -> {:error, "missing Git history: #{path}"}
      {timestamp, 0} -> {:ok, timestamp |> String.trim() |> String.to_integer() |> DateTime.from_unix!()}
      {output, _} -> {:error, "Git history error for #{path}: #{String.trim(output)}"}
    end
  end

  defp print_report(report, "json"), do: Mix.shell().info(Jason.encode!(report, pretty: true))

  defp print_report(report, "human") do
    Enum.each(report.references, fn record ->
      if record.status != "valid" do
        Mix.shell().info("#{record.status} kind=#{record.kind} document=#{record.document} line=#{record.line} token=#{record.token} reason=#{record.reason}")
      end
    end)

    Enum.each(report.allowlist_errors, &Mix.shell().info("error allowlist #{Jason.encode!(&1)}"))

    Enum.each(report.freshness, fn record ->
      Mix.shell().info(
        "#{record.status} document=#{record.document} owner=#{record.owner || "null"} " <>
          "doc_last_modified=#{record.doc_last_modified || "null"} owner_last_touched=#{record.owner_last_touched || "null"} " <>
          "delta_days=#{if is_nil(record.delta_days), do: "null", else: record.delta_days} status=#{record.status}" <>
          if(record.reason, do: " reason=#{record.reason}", else: "")
      )
    end)

    s = report.summary
    Mix.shell().info("docs.drift: #{s.documents} documents, #{s.references} references, #{s.exempt} exempt, #{s.stale} stale, #{s.skipped} skipped, #{s.errors} errors")
  end
end

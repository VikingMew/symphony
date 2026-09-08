#!/usr/bin/env elixir

pattern = ~r/\b(refute_receive|refute_match|refute_in_delta|refute|flunk)\b/

classify = fn macro, source ->
  cond do
    macro == "refute_receive" ->
      {"timing", "retain", "ExUnit mailbox timeout contract"}

    Regex.match?(~r/(secret|token|credential|DATABASE_URL|POSTGRES_|privileged|\.sock|x-access-token)/i, source) ->
      {"security-redline", "retain-with-contract", "security owning contract"}

    Regex.match?(~r/(compose|dockerfile|workflow|worker|proxy|forwarded)/i, source) ->
      {"deployment-capability", "review", "docs/compose.md or docs/deployment.md"}

    Regex.match?(~r/(Map\.has_key\?|MapSet\.|File\.exists\?|Process\.|\.valid\?|==|\bin\b)/, source) ->
      {"structure-data", "rewrite-exact", "tested data/state contract"}

    macro == "flunk" ->
      {"control-flow", "rewrite-match", "explicit success shape"}

    true ->
      {"implementation-detail", "review-delete-or-positive", "nearest owning contract"}
  end
end

rows =
  Path.wildcard("test/**/*.{ex,exs}")
  |> Enum.sort()
  |> Enum.flat_map(fn path ->
    path
    |> File.stream!()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(pattern, line) do
        [_, macro] ->
          source = String.trim(line)
          {category, decision, contract} = classify.(macro, source)
          [[path, number, macro, category, decision, contract, source]]

        nil ->
          []
      end
    end)
  end)

escape = fn value ->
  value
  |> to_string()
  |> String.replace("\t", "\\t")
  |> String.replace("\n", "\\n")
end

output =
  [["file", "line", "macro", "category", "decision", "contract", "source"] | rows]
  |> Enum.map_join("\n", fn row -> Enum.map_join(row, "\t", escape) end)

IO.puts(output)

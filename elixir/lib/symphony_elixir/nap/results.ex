defmodule SymphonyElixir.Nap.Results do
  @moduledoc """
  Deterministic result aggregation and in-run deduplication for operator audit tasks.
  """

  @type finding :: map()
  @type result :: %{status: atom(), finding: finding(), fingerprint: String.t(), issue: map() | nil, reason: String.t() | nil}

  @spec fingerprint(finding()) :: String.t()
  def fingerprint(%{} = finding) do
    [
      get_string(finding, "title"),
      get_string(finding, "category"),
      get_string(finding, "path"),
      get_string(finding, "symbol"),
      get_string(finding, "evidence")
    ]
    |> Enum.join("|")
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec aggregate([finding()], (finding() -> {:ok, map()} | {:error, term()})) :: %{created: non_neg_integer(), skipped: non_neg_integer(), failed: non_neg_integer(), results: [result()]}
  def aggregate(findings, create_fun) when is_list(findings) and is_function(create_fun, 1) do
    {_seen, results} =
      Enum.reduce(findings, {MapSet.new(), []}, fn finding, {seen, results} ->
        fp = fingerprint(finding)

        cond do
          MapSet.member?(seen, fp) ->
            {seen, [%{status: :skipped_duplicate, finding: finding, fingerprint: fp, issue: nil, reason: nil} | results]}

          invalid_finding?(finding) ->
            {MapSet.put(seen, fp), [%{status: :validation_failed, finding: finding, fingerprint: fp, issue: nil, reason: "missing required finding fields"} | results]}

          true ->
            case create_fun.(finding) do
              {:ok, issue} -> {MapSet.put(seen, fp), [%{status: :created, finding: finding, fingerprint: fp, issue: issue, reason: nil} | results]}
              {:error, reason} -> {MapSet.put(seen, fp), [%{status: :create_failed, finding: finding, fingerprint: fp, issue: nil, reason: inspect(reason)} | results]}
            end
        end
      end)

    results = Enum.reverse(results)

    %{
      created: Enum.count(results, &(&1.status == :created)),
      skipped: Enum.count(results, &(&1.status == :skipped_duplicate)),
      failed: Enum.count(results, &(&1.status in [:validation_failed, :create_failed])),
      results: results
    }
  end

  defp invalid_finding?(finding) do
    Enum.any?(["title", "category", "evidence"], &(get_string(finding, &1) == ""))
  end

  defp get_string(map, key) do
    value = SymphonyElixir.Payload.get_any(map, finding_keys(key))
    if is_binary(value), do: String.trim(value), else: ""
  end

  defp finding_keys("title"), do: ["title", :title]
  defp finding_keys("category"), do: ["category", :category]
  defp finding_keys("path"), do: ["path", :path]
  defp finding_keys("symbol"), do: ["symbol", :symbol]
  defp finding_keys("evidence"), do: ["evidence", :evidence]
  defp finding_keys(_key), do: []
end

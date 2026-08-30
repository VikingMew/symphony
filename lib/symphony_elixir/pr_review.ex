defmodule SymphonyElixir.PRReview do
  @moduledoc "Typed, deterministic primitives for post-handoff pull-request reviews."

  @type outcome :: :approve | :findings
  @type result :: %{
          required(:outcome) => outcome(),
          required(:head_sha) => String.t(),
          required(:summary) => String.t(),
          optional(:findings) => [String.t()]
        }

  @spec identity(String.t(), String.t(), String.t()) :: String.t()
  def identity(issue_id, pr_url, head_sha)
      when is_binary(issue_id) and is_binary(pr_url) and is_binary(head_sha),
      do: :crypto.hash(:sha256, Enum.join([issue_id, pr_url, head_sha], "\0")) |> Base.encode16(case: :lower)

  @spec normalize(map()) :: {:ok, result()} | {:error, term()}
  def normalize(%{"outcome" => outcome, "head_sha" => sha, "summary" => summary} = value),
    do: normalize(Map.merge(value, %{outcome: outcome, head_sha: sha, summary: summary}))

  def normalize(%{outcome: outcome, head_sha: sha, summary: summary} = value)
      when outcome in [:approve, :findings] and is_binary(sha) and sha != "" and is_binary(summary) do
    findings = Map.get(value, :findings, Map.get(value, "findings", []))

    if is_list(findings) and Enum.all?(findings, &is_binary/1),
      do: {:ok, %{outcome: outcome, head_sha: sha, summary: summary, findings: findings}},
      else: {:error, :invalid_findings}
  end

  def normalize(_), do: {:error, :invalid_review_result}

  @spec comment(result()) :: String.t()
  def comment(%{outcome: :approve, head_sha: sha, summary: summary}),
    do: "Symphony PR review: APPROVE (head #{sha})\n#{summary}"

  def comment(%{outcome: :findings, head_sha: sha, summary: summary, findings: findings}) do
    items = findings |> Enum.with_index(1) |> Enum.map_join("\n", fn {f, i} -> "#{i}. #{f}" end)
    "Symphony PR review: FINDINGS (head #{sha})\n#{summary}\n\n#{items}"
  end
end

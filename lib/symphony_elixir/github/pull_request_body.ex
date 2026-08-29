defmodule SymphonyElixir.GitHub.PullRequestBody do
  @moduledoc """
  Deterministically renders the initial pull request from an implementation completion result.
  """

  alias SymphonyElixir.Linear.Issue

  @type rendered :: %{title: String.t(), body: String.t()}

  @spec render(Issue.t(), map()) :: {:ok, rendered()} | {:error, term()}
  def render(%Issue{} = issue, result) when is_map(result) do
    with {:ok, identifier} <- required_line(issue.identifier, :identifier),
         {:ok, title} <- required_line(issue.title, :title),
         {:ok, completed} <- required_content(result, "completed"),
         {:ok, validation} <- required_content(result, "validation") do
      {:ok,
       %{
         title: "#{identifier}: #{title}",
         body: """
         #### Summary

         #{bullets(completed, "- ")}

         #### Test Plan

         #{bullets(validation, "- [x] ")}

         Fixes #{identifier}
         """
         |> String.trim()
       }}
    end
  end

  defp required_content(result, field) do
    case Map.get(result, field) do
      value when is_binary(value) -> required_text(value, field)
      _ -> {:error, {:implementation_handoff_result_invalid, field}}
    end
  end

  defp required_line(value, field) when is_binary(value) do
    with {:ok, text} <- required_text(value, field),
         false <- String.contains?(text, ["\n", "\r"]) do
      {:ok, text}
    else
      true -> {:error, {:implementation_handoff_result_invalid, field}}
      error -> error
    end
  end

  defp required_line(_value, field), do: {:error, {:implementation_handoff_result_invalid, field}}

  defp required_text(value, field) do
    case String.trim(value) do
      "" -> {:error, {:implementation_handoff_result_invalid, field}}
      text -> {:ok, text}
    end
  end

  defp bullets(content, prefix) do
    content
    |> String.split(~r/\R/, trim: true)
    |> Enum.map_join("\n", &(prefix <> String.trim(&1)))
  end
end

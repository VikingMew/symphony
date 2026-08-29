defmodule SymphonyElixir.GitHub.PullRequestBodyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.PullRequestBody
  alias SymphonyElixir.Linear.Issue

  test "renders the typed completion result deterministically" do
    result = %{"completed" => "first change\nsecond change", "validation" => "mix test\nmake all"}

    assert {:ok, rendered} = PullRequestBody.render(issue(), result)
    assert rendered.title == "SYM-21: Govern PR bodies"

    assert rendered.body == """
           #### Summary

           - first change
           - second change

           #### Test Plan

           - [x] mix test
           - [x] make all

           Fixes SYM-21
           """
           |> String.trim()
  end

  test "rejects missing or empty typed completion fields" do
    assert {:error, {:implementation_handoff_result_invalid, "completed"}} =
             PullRequestBody.render(issue(), %{"validation" => "green"})

    assert {:error, {:implementation_handoff_result_invalid, "validation"}} =
             PullRequestBody.render(issue(), %{"completed" => "done", "validation" => " "})
  end

  defp issue do
    %Issue{identifier: "SYM-21", title: "Govern PR bodies"}
  end
end

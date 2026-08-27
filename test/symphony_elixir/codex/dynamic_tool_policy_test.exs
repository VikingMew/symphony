defmodule SymphonyElixir.Codex.DynamicTool.PolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.DynamicTool.Policy

  test "normalizes update arguments and rejects invalid fields" do
    assert {:ok, %{"comment" => "done", "target_state" => "Review"}} =
             Policy.normalize_update_arguments(%{"comment" => "done", "target_state" => "Review"})

    assert {:error, :empty_update} = Policy.normalize_update_arguments(%{})
    assert {:error, {:invalid_field, "references"}} = Policy.normalize_update_arguments(%{"references" => ["bad"]})
  end

  test "validates allowed update policy" do
    policy = %{
      "comment" => true,
      "description" => false,
      "result" => true,
      "target_states" => ["In Progress", "Ready to Merge"]
    }

    assert :ok =
             Policy.validate_update_policy(
               %{
                 "comment" => "ok",
                 "result" => %{"validation" => "green"},
                 "references" => %{"branch" => "feature/sym-1"},
                 "target_state" => "Ready to Merge"
               },
               policy,
               "implementation"
             )

    assert {:error, {:update_not_allowed, "description", "implementation"}} = Policy.validate_update_policy(%{"description" => "no"}, policy, "implementation")

    assert {:error, {:target_state_not_allowed, "Done", "implementation", ["In Progress", "Ready to Merge"]}} =
             Policy.validate_update_policy(%{"target_state" => "Done"}, policy, "implementation")
  end

  test "extracts and deduplicates concrete reference links" do
    links =
      Policy.reference_link_candidates(%{
        "references" => %{
          "pr_url" => "https://github.com/acme/app/pull/1",
          "branch" => "codex/MT-1",
          "urls" => ["https://example.test/artifact", "not-a-url"]
        },
        "result" => %{"commit_url" => "https://github.com/acme/app/commit/abc", "duplicate" => "https://example.test/artifact"}
      })

    assert links == [
             %{title: "Pull Request", url: "https://github.com/acme/app/pull/1"},
             %{title: "Reference", url: "https://example.test/artifact"},
             %{title: "Commit", url: "https://github.com/acme/app/commit/abc"}
           ]
  end
end

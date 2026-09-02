defmodule SymphonyElixir.Codex.DynamicTool.PolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.DynamicTool.Policy

  test "normalizes update arguments and rejects invalid fields" do
    assert {:ok, %{"comment" => "done", "target_state" => "Review"}} =
             Policy.normalize_update_arguments(%{"comment" => "done", "target_state" => "Review"})

    assert {:error, :empty_update} = Policy.normalize_update_arguments(%{})
    assert {:error, {:invalid_field, "references"}} = Policy.normalize_update_arguments(%{"references" => ["bad"]})
  end

  test "accepts legacy and Codex pull request reference pairs without mixing" do
    legacy = %{"references" => %{"pr_url" => "https://github.com/acme/app/pull/1", "pr_proof" => "proof"}}
    codex = %{"references" => %{"pull_request" => "https://github.com/acme/app/pull/2", "pull_request_completion_proof" => "proof-2"}}

    assert {:ok, "https://github.com/acme/app/pull/1", "proof"} = Policy.pull_request_reference(legacy)
    assert {:ok, "https://github.com/acme/app/pull/2", "proof-2"} = Policy.pull_request_reference(codex)

    assert {:error, {:implementation_handoff_field_required, _}} =
             Policy.pull_request_reference(%{"references" => %{"pr_url" => "https://github.com/acme/app/pull/1", "pull_request_completion_proof" => "proof"}})

    assert {:error, {:implementation_handoff_field_required, _}} =
             Policy.pull_request_reference(%{"references" => %{"pr_url" => "https://github.com/acme/app/pull/1", "pr_proof" => ""}})

    assert {:error, {:implementation_handoff_field_required, _}} =
             Policy.pull_request_reference(%{"references" => %{"pull_request" => "https://github.com/acme/app/pull/2"}})

    assert {:error, {:implementation_handoff_field_required, _}} =
             Policy.pull_request_reference(%{"references" => %{"pull_request" => "https://example.com/pr/1", "pull_request_completion_proof" => "proof"}})

    assert {:error, {:implementation_handoff_field_required, _}} =
             Policy.pull_request_reference(%{"references" => %{"pr_url" => "", "pr_proof" => "proof"}})
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

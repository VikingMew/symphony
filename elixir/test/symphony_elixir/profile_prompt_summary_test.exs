defmodule SymphonyElixir.ProfilePromptSummaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProfilePromptSummary

  test "summarizes extend replace disabled and non-codex prompt behavior" do
    base = "Shared base prompt"

    extend =
      ProfilePromptSummary.profile_summary(base, "implementation", %{
        "executor_type" => "codex_agent",
        "prompt_mode" => "extend",
        "prompt_template" => "Implementation prompt"
      })

    assert extend.uses_base_prompt?
    assert extend.template_chars == String.length("Implementation prompt")
    assert extend.effective_chars == String.length("Implementation prompt\n\nShared base prompt")
    assert extend.composition =~ "extends the Base Prompt"
    assert is_nil(extend.warning)

    replace =
      ProfilePromptSummary.profile_summary(base, "refinement", %{
        "executor_type" => "codex_agent",
        "prompt_mode" => "replace",
        "prompt_template" => "Refine only"
      })

    refute replace.uses_base_prompt?
    assert replace.effective_chars == String.length("Refine only")
    assert replace.composition =~ "replaces the Base Prompt"

    disabled =
      ProfilePromptSummary.profile_summary(base, "merge", %{
        "executor_type" => "codex_agent",
        "prompt_mode" => "disabled",
        "prompt_template" => "Ignored profile prompt"
      })

    assert disabled.uses_base_prompt?
    assert disabled.effective_chars == String.length(base)
    assert disabled.composition =~ "Base Prompt is used by itself"

    backend =
      ProfilePromptSummary.profile_summary(base, "backend", %{
        "executor_type" => "backend_action",
        "prompt_mode" => "extend",
        "prompt_template" => "Not used"
      })

    refute backend.prompt_used?
    assert is_nil(backend.effective_chars)
    assert backend.composition =~ "not used by this executor"
  end

  test "warns about codex profiles with thin prompt composition and summarizes page counts" do
    profiles = %{
      "empty_extend" => %{"executor_type" => "codex_agent", "prompt_mode" => "extend", "prompt_template" => ""},
      "empty_replace" => %{"executor_type" => "codex_agent", "prompt_mode" => "replace", "prompt_template" => ""},
      "manual" => %{"executor_type" => "manual", "prompt_mode" => "extend", "prompt_template" => ""}
    }

    extend = ProfilePromptSummary.profile_summary("", "empty_extend", profiles["empty_extend"])
    replace = ProfilePromptSummary.profile_summary("Base", "empty_replace", profiles["empty_replace"])
    manual = ProfilePromptSummary.profile_summary("", "manual", profiles["manual"])

    assert extend.warning =~ "no useful Base Prompt"
    assert replace.warning =~ "replaces the Base Prompt"
    assert is_nil(manual.warning)

    page = ProfilePromptSummary.page_summary("", profiles)
    assert page.base_chars == 0
    assert page.profiles_with_templates == 0
    assert page.profiles_with_warnings == 2
  end
end

defmodule SymphonyElixir.PromptBuilderTest do
  use SymphonyElixir.TestSupport

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder uses the active persisted project workflow" do
    {:ok, base} = Workflow.load()
    {:ok, project_a} = FakePersistence.default_project()
    {:ok, _} = FakePersistence.import_workflow(project_a, Workflow.to_markdown(base.config, "Prompt A"), "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        repository_url: "git@example.test:b.git",
        enabled: true
      })

    {:ok, _} =
      FakePersistence.import_workflow(
        project_b,
        Workflow.to_markdown(base.config, "Prompt B {{ issue.identifier }}"),
        "test"
      )

    assert :ok = WorkflowStore.force_reload()
    {:ok, workflow_b} = WorkflowStore.for_project(project_b.id)
    issue = %Issue{identifier: "B-1", title: "Project B", state: "Ready", labels: []}

    prompt = Config.with_workflow_context(workflow_b, fn -> PromptBuilder.build_prompt(issue) end)

    assert prompt == "Prompt B B-1"
  end

  test "prompt builder prepends profile-specific tool contract when profile is provided" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "S-2",
      title: "Implement profile prompt",
      description: "Prompt should include workflow tool guidance",
      state: "In Progress",
      url: "https://example.org/issues/S-2",
      labels: ["backend"]
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        profile: "implementation",
        allowed_updates: %{"target_states" => ["Ready to Merge"]}
      )

    assert prompt =~ "Workflow profile: implementation"
    assert prompt =~ "`linear_task_read`"
    assert prompt =~ "`linear_task_update`"
    assert prompt =~ "Ready to Merge"
    assert prompt =~ "Ticket S-2"
  end

  test "implementation profile directs Codex to the handoff skill contract" do
    profiles = File.read!(Path.expand("../../profiles.yml", __DIR__))
    skill = File.read!(Path.expand("../../.codex/skills/handoff/SKILL.md", __DIR__))

    assert profiles =~ "## Related skills"
    assert profiles =~ "`handoff`:"
    assert skill =~ "target_state: \"Ready to Merge\""
    assert skill =~ "`comment`"
    assert skill =~ "`result`"
    assert skill =~ "`references`"
    assert skill =~ "pr_url"
    assert skill =~ "pull_request_completion_proof"
    assert skill =~ "\"blockers\": \"\""
  end

  test "default nap and day dreaming profiles are issue-only prompts" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Base {{ issue.identifier }}")

    issue = %Issue{
      identifier: "S-NAP",
      title: "Audit task",
      description: "Audit the repository",
      state: "Ready",
      url: "https://example.org/issues/S-NAP",
      labels: []
    }

    profiles = Config.Schema.default_profiles()

    nap_prompt =
      PromptBuilder.build_prompt(issue,
        profile: "nap",
        profile_policy: Map.fetch!(profiles, "nap"),
        allowed_updates: %{"target_states" => []}
      )

    assert nap_prompt =~ "redundant error handling"
    assert nap_prompt =~ "redundant gating"
    assert nap_prompt =~ "mutual dependencies"
    assert nap_prompt =~ "Dead weight"
    assert nap_prompt =~ "Linus"
    assert nap_prompt =~ "Carmack"
    assert nap_prompt =~ "mechanical scan pre-step"
    assert nap_prompt =~ "`mix xref graph`"
    assert nap_prompt =~ "`mix deps.tree` plus dependency-unused checks"
    assert nap_prompt =~ "Credo duplicate-code and cyclomatic-complexity checks"
    assert nap_prompt =~ "`mix dialyzer`"
    assert nap_prompt =~ "OTP28 `unused_fun` has known false positives"
    assert nap_prompt =~ "Tool output is evidence, not a verdict"
    assert nap_prompt =~ "Stale exemption lists"
    assert nap_prompt =~ "`.dialyzer_ignore.exs`"
    assert nap_prompt =~ "`@tag :skip` tests"
    assert nap_prompt =~ "Unconsumed public APIs and events"
    assert nap_prompt =~ "event topics with no real consumer"
    assert nap_prompt =~ "source of truth already exists in code"
    assert nap_prompt =~ "Archive stale documentation instead of physically deleting it"
    assert nap_prompt =~ "Gate-then-zero fix directions"
    assert nap_prompt =~ "discovery path (mechanical scan output or manual review)"
    assert nap_prompt =~ "verification path"
    assert nap_prompt =~ "Re-check every mechanical result manually"
    assert nap_prompt =~ "pure deletion from reorganization or migration"
    assert nap_prompt =~ "write Keep as-is"
    assert nap_prompt =~ "one Backlog Linear issue"
    assert nap_prompt =~ "complexity impact"
    assert nap_prompt =~ "fix direction that reduces complexity"
    assert nap_prompt =~ "Do not modify code"
    assert nap_prompt =~ "Do not modify documentation"

    day_dreaming_prompt =
      PromptBuilder.build_prompt(issue,
        profile: "day_dreaming",
        profile_policy: Map.fetch!(profiles, "day_dreaming"),
        allowed_updates: %{"target_states" => []}
      )

    assert day_dreaming_prompt =~ "long-term direction docs"
    assert day_dreaming_prompt =~ "features or optimization opportunities"
    assert day_dreaming_prompt =~ "one Backlog Linear issue"
    assert day_dreaming_prompt =~ "not duplicate an existing Backlog issue"
    assert day_dreaming_prompt =~ "Do not modify code"
    assert day_dreaming_prompt =~ "Do not modify documentation"
  end

  test "fresh workflow config uses the code default operator profiles" do
    defaults = Config.Schema.default_profiles()
    fresh_profiles = Workflow.setup_required_workflow().config["profiles"]

    assert Map.take(fresh_profiles, ["nap", "day_dreaming"]) ==
             Map.take(defaults, ["nap", "day_dreaming"])
  end

  test "prompt builder applies profile prompt templates" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Base {{ issue.identifier }}")

    issue = %Issue{
      identifier: "S-3",
      title: "Implement profile prompt template",
      description: "Prompt should use the profile prompt policy",
      state: "Ready",
      url: "https://example.org/issues/S-3",
      labels: ["backend"]
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        profile: "implementation",
        profile_policy: %{
          "name" => "Implementation",
          "prompt" => %{"mode" => "extend", "template" => "Stage {{ workflow.profile_name }} {{ issue.identifier }}"}
        },
        allowed_updates: %{"target_states" => ["Ready to Merge"]}
      )

    assert prompt =~ "Stage Implementation S-3"
    assert prompt =~ "Base S-3"
    assert String.starts_with?(prompt, "Stage Implementation S-3\n\nBase S-3\n\n")

    prompt =
      PromptBuilder.build_prompt(issue,
        profile: "implementation",
        profile_policy: %{
          "name" => "Implementation",
          "prompt" => %{"mode" => "replace", "template" => "Replace {{ issue.identifier }}"}
        },
        allowed_updates: %{"target_states" => ["Ready to Merge"]}
      )

    assert String.starts_with?(prompt, "Replace S-3\n\n")
  end

  test "refinement and implementation prompts enforce cross-project container validation policy" do
    issue = %Issue{
      identifier: "OTHER-1",
      title: "Validate another repository",
      description: "Validation: build and inspect the image",
      state: "In Progress",
      url: "https://example.org/issues/OTHER-1",
      labels: []
    }

    for {project_prompt, profile} <- [
          {"Project alpha requires every ticket Validation instruction", "refinement"},
          {"Project beta requires every Test Plan instruction", "implementation"}
        ] do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: project_prompt)

      prompt =
        PromptBuilder.build_prompt(issue,
          profile: profile,
          profile_policy: %{
            "prompt" => %{"mode" => "extend", "template" => "Execute every Testing requirement"}
          }
        )

      assert prompt =~ project_prompt
      assert prompt =~ "Container-engine validation policy (highest priority)"
      assert prompt =~ "every configured project and target repository"
      assert prompt =~ "do not invoke `docker`, `docker compose`, `buildx`, `podman`, `nerdctl`"
      assert prompt =~ "Do not build, pull, run, push, inspect, or publish container images"
      assert prompt =~ "record the exact conflict as blocker evidence"
      assert prompt =~ "`blocking_decision` / `Blocked` workflow"
      assert prompt =~ "true blocker even though it is not missing authentication"
      assert prompt =~ "Continue to execute all required validation that this policy allows"

      assert :binary.match(prompt, "Execute every Testing requirement") <
               :binary.match(prompt, "Container-engine validation policy (highest priority)")
    end

    replace_prompt =
      PromptBuilder.build_prompt(issue,
        profile: "implementation",
        profile_policy: %{
          "prompt" => %{"mode" => "replace", "template" => "Replacement project contract"}
        }
      )

    assert replace_prompt =~ "Replacement project contract"
    assert replace_prompt =~ "Container-engine validation policy (highest priority)"
  end

  test "profiles import artifact carries the same container validation priority" do
    profiles = File.read!("profiles.yml")

    assert profiles =~ "Container-engine validation policy (highest priority)"
    assert profiles =~ "policy-prohibited required validation is a true blocker"
    assert profiles =~ "execute every allowed ticket-provided"
  end

  test "prompt builder renders built-in refinement and custom profile contracts" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Base {{ issue.identifier }}")

    issue = %Issue{
      identifier: "S-4",
      title: "Exercise profile contracts",
      description: "Prompt should explain each profile",
      state: "Ready",
      url: "https://example.org/issues/S-4",
      labels: []
    }

    refinement_prompt =
      PromptBuilder.build_prompt(issue,
        profile: "refinement",
        allowed_updates: %{"target_states" => ["Needs Refinement Review"]}
      )

    assert refinement_prompt =~ "Workflow profile: refinement"
    assert refinement_prompt =~ "Needs Refinement Review"
    assert refinement_prompt =~ "Base S-4"

    custom_prompt =
      PromptBuilder.build_prompt(issue,
        profile: "qa",
        allowed_updates: %{}
      )

    assert custom_prompt =~ "Workflow profile: qa"
    assert custom_prompt =~ "the profile's allowed target states"
    assert custom_prompt =~ "Base S-4"
  end

  test "prompt builder supports disabled profile prompts and implementation branch contract" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Base {{ issue.identifier }}")

    issue = %Issue{
      identifier: "S-5",
      title: "Exercise implementation branch contract",
      description: "Prompt should mention Linear branchName",
      state: "In Progress",
      url: "https://example.org/issues/S-5",
      labels: [],
      branch_name: "feature/s-5"
    }

    disabled_prompt =
      PromptBuilder.build_prompt(issue,
        profile: "implementation",
        profile_policy: %{"prompt" => %{"mode" => "disabled"}},
        allowed_updates: %{"target_states" => ["Ready to Merge"]}
      )

    assert String.starts_with?(disabled_prompt, "Base S-5\n\n")

    branch_prompt =
      PromptBuilder.build_prompt(issue,
        profile: "implementation",
        allowed_updates: %{"target_states" => ["Ready to Merge"]}
      )

    assert branch_prompt =~ "Required branch: `feature/s-5`"
    assert branch_prompt =~ "Do not create or switch to a different task branch."
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder uses setup-required prompt when the database has no workflow" do
    FakePersistence.reset!()
    assert :ok = WorkflowStore.force_reload()

    issue = %Issue{
      identifier: "MT-780",
      title: "Setup workflow",
      description: "No active workflow",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "Create a workflow from the Web UI to start running agents."
  end

  test "in-repo split package renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    repo_workflow_path = Path.expand("workflow.yml", File.cwd!())
    Workflow.set_workflow_file_path(repo_workflow_path)
    {:ok, loaded} = Workflow.load(repo_workflow_path)
    raw = Workflow.to_markdown(loaded.config, loaded.prompt)
    {:ok, project} = FakePersistence.default_project()
    {:ok, _version} = FakePersistence.import_workflow(project, raw, "test")
    WorkflowStore.force_reload()

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for profile prompts",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for profile prompts"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "create_pull_request"
    assert prompt =~ "docs/pull-request-body.md"
    assert prompt =~ "Linear `branchName` is the only implementation head branch source of truth"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end
end

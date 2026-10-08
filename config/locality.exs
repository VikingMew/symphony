%{
  generated: [],
  code_extensions: [".conf", ".css", ".ex", ".exs", ".heex", ".js", ".py", ".sh", ".toml", ".yaml", ".yml"],
  code_basenames: [".dockerignore", ".env.example", ".gitignore", "Dockerfile", "Makefile", "symphony"],
  data_paths: [".github/media/elixir-screenshot.png", ".github/media/symphony-demo-poster.jpg", ".github/media/symphony-demo.mp4", "docs/negative-assertion-inventory.tsv", "mix.lock"],
  clause_exceptions: [
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/analytics.ex",
      lines: 61,
      identifier: "quality/6@83"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/codex/app_server.ex",
      lines: 89,
      identifier: "handle_incoming/7@631"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/codex/app_server.ex",
      lines: 77,
      identifier: "handle_turn_method/7@799"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/codex/app_server.ex",
      lines: 102,
      identifier: "run_turn/4@87"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/codex/dynamic_tool/sections/request_execution.ex",
      lines: 574,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/codex/dynamic_tool/sections/dynamic_tool_updates.ex",
      lines: 661,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/config/schema/sections/defaults.ex",
      lines: 285,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/config/schema/sections/defaults.ex",
      lines: 79,
      identifier: "default_profiles/0@85"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/config/schema/sections/parsing.ex",
      lines: 271,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/config/schema/sections/types.ex",
      lines: 518,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/completion.ex",
      lines: 338,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/control.ex",
      lines: 918,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/orchestrator/sections/control.ex",
      lines: 99,
      identifier: "handle_call/3@255"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/dispatch.ex",
      lines: 714,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/orchestrator/sections/dispatch.ex",
      lines: 86,
      identifier: "dispatch_issue_agent/8@167"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/lifecycle.ex",
      lines: 737,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/orchestrator_persistence.ex",
      lines: 401,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/reconciliation.ex",
      lines: 806,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/runtime_status.ex",
      lines: 888,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/worker/assignment_manager/sections/api.ex",
      lines: 781,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/worker/assignment_manager/sections/assignment.ex",
      lines: 852,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/worker/executor.ex",
      lines: 72,
      identifier: "execute/3@20"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/worker/executor.ex",
      lines: 71,
      identifier: "run_codex/5@93"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/workspace/sections/hooks.ex",
      lines: 572,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/workspace/sections/workspace_lifecycle.ex",
      lines: 563,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/workspace/sections/workspace_lifecycle.ex",
      lines: 66,
      identifier: "prepare_worktree_source/4@271"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/events.ex",
      lines: 111,
      identifier: "render/1@11"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/run_detail.ex",
      lines: 107,
      identifier: "render/1@13"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/agents.ex",
      lines: 164,
      identifier: "render/1@14"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/import.ex",
      lines: 83,
      identifier: "render/1@15"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/projects.ex",
      lines: 147,
      identifier: "render/1@14"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/runtime.ex",
      lines: 180,
      identifier: "render/1@16"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/analytics_live.ex",
      lines: 150,
      identifier: "render/1@22"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/dashboard_live.ex",
      lines: 431,
      identifier: "render/1@118"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/linear_diagnostics_live.ex",
      lines: 259,
      identifier: "render/1@65"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/workers_live.ex",
      lines: 92,
      identifier: "render/1@19"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "mix.exs",
      lines: 136,
      identifier: "coverage_ignore_groups/0@53"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "priv/repo/migrations/20260501000000_create_symphony_persistence.exs",
      lines: 132,
      identifier: "change/0@5"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "priv/repo/migrations/20260501001000_create_worker_control_plane.exs",
      lines: 72,
      identifier: "change/0@5"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/fake_persistence_sections/fake_persistence_1.exs",
      lines: 620,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/fake_persistence_sections/fake_persistence_2.exs",
      lines: 659,
      identifier: "__using__/1@6"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/agent_runner_1.exs",
      lines: 613,
      identifier: "__using__/1@11"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/agent_runner_2.exs",
      lines: 468,
      identifier: "__using__/1@11"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/assignment_manager_1.exs",
      lines: 718,
      identifier: "__using__/1@16"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/assignment_manager_2.exs",
      lines: 772,
      identifier: "__using__/1@18"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/assignment_manager_3.exs",
      lines: 507,
      identifier: "__using__/1@20"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/core_1.exs",
      lines: 762,
      identifier: "__using__/1@13"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/core_2.exs",
      lines: 685,
      identifier: "__using__/1@15"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/extensions_1.exs",
      lines: 645,
      identifier: "__using__/1@16"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/extensions_2.exs",
      lines: 550,
      identifier: "__using__/1@13"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_1.exs",
      lines: 838,
      identifier: "__using__/1@10"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_2.exs",
      lines: 665,
      identifier: "__using__/1@11"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_3.exs",
      lines: 617,
      identifier: "__using__/1@13"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_4.exs",
      lines: 348,
      identifier: "__using__/1@10"
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/test_support.exs",
      lines: 95,
      identifier: "__using__/1@123"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "test/support/test_support.exs",
      lines: 152,
      identifier: "workflow_content/1@330"
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "test/symphony_elixir/live_e2e_test.exs",
      lines: 82,
      identifier: "run_live_issue_flow!/1@410"
    }
  ]
}

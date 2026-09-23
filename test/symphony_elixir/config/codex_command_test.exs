defmodule SymphonyElixir.Config.CodexCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.CodexCommand
  alias SymphonyElixir.Workflow

  test "migration promotes missing selectors and rewrites both workflow representations" do
    config = %{
      "codex" => %{
        "command" => "codex --config 'model=\"gpt-5.5\"' -c model_reasoning_effort=xhigh app-server"
      }
    }

    assert {:changed, migrated} = CodexCommand.migrate_config(config)

    assert migrated["codex"] == %{
             "command" => "codex app-server",
             "model" => "gpt-5.5",
             "reasoning_effort" => "xhigh"
           }

    raw = Workflow.to_markdown(migrated, "Prompt")
    assert {:ok, loaded} = Workflow.parse_content(raw)
    assert loaded.config == migrated
    assert loaded.prompt == "Prompt"
  end

  test "migration preserves explicit selectors and removes every legacy override" do
    config = %{
      "codex" => %{
        "command" => "codex --config network_access=true -m gpt-5.5 --config=model_reasoning_effort=xhigh app-server",
        "model" => "gpt-5.6-sol",
        "reasoning_effort" => "high"
      }
    }

    assert {:changed, migrated} = CodexCommand.migrate_config(config)

    assert get_in(migrated, ["codex", "command"]) ==
             "codex --config network_access=true app-server"

    assert get_in(migrated, ["codex", "model"]) == "gpt-5.6-sol"
    assert get_in(migrated, ["codex", "reasoning_effort"]) == "high"

    raw = Workflow.to_markdown(migrated, "Existing selector prompt")
    assert {:ok, loaded} = Workflow.parse_content(raw)
    assert loaded.config == migrated
    assert loaded.prompt == "Existing selector prompt"
  end

  test "reported persisted workflow outcomes follow selector precedence" do
    existing = %{
      "codex" => %{
        "command" => "codex -c model=gpt-5.5 -c model_reasoning_effort=xhigh app-server",
        "model" => "gpt-5.6-sol",
        "reasoning_effort" => "high"
      }
    }

    assert {:changed, symphony} = CodexCommand.migrate_config(existing)

    assert symphony["codex"] == %{
             "command" => "codex app-server",
             "model" => "gpt-5.6-sol",
             "reasoning_effort" => "high"
           }

    missing = %{
      "codex" => %{
        "command" => "codex -c model=gpt-5.5 -c model_reasoning_effort=xhigh app-server"
      }
    }

    for _project <- ["claude-code-router-rust", "Default", "Koroni", "quickpython"] do
      assert {:changed, migrated} = CodexCommand.migrate_config(missing)

      assert migrated["codex"] == %{
               "command" => "codex app-server",
               "model" => "gpt-5.5",
               "reasoning_effort" => "xhigh"
             }
    end
  end

  test "migration updates the current instance authority and unresolved candidates" do
    instance = %{
      "config" => %{
        "codex" => %{
          "command" => "codex -c model=gpt-5.5 -c model_reasoning_effort=xhigh app-server"
        }
      },
      "prompt_body" => "Prompt"
    }

    assert {:changed, migrated_instance} = CodexCommand.migrate_instance(instance)
    assert get_in(migrated_instance, ["config", "codex", "command"]) == "codex app-server"
    assert get_in(migrated_instance, ["config", "codex", "model"]) == "gpt-5.5"
    assert get_in(migrated_instance, ["config", "codex", "reasoning_effort"]) == "xhigh"

    conflict = %{
      "candidates" => [
        %{"project_slug" => "Default", "candidate" => instance},
        %{"project_slug" => "Symphony", "candidate" => migrated_instance}
      ],
      "differing_paths" => []
    }

    assert {:changed, migrated_conflict} = CodexCommand.migrate_conflict(conflict)

    assert Enum.all?(migrated_conflict["candidates"], fn candidate ->
             get_in(candidate, ["candidate", "config", "codex", "command"]) ==
               "codex app-server"
           end)
  end
end

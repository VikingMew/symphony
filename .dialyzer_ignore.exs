unused_functions = [
  # Builds the message callback passed to live issue and operator Codex turns.
  {:unused_fun, {SymphonyElixir.AgentRunner, :codex_message_handler, 2}},
  # Delivers messages emitted through the retained Codex turn callback.
  {:unused_fun, {SymphonyElixir.AgentRunner, :send_codex_update, 3}},
  # Runs after a successful app-server session and before the first issue turn.
  {:unused_fun, {SymphonyElixir.AgentRunner, :maybe_mark_implementation_started, 2}},
  # Performs the required Ready-to-In-Progress transition before implementation.
  {:unused_fun, {SymphonyElixir.AgentRunner, :transition_implementation_start, 3}},
  # Guards the retained implementation-start transition with workflow policy.
  {:unused_fun, {SymphonyElixir.AgentRunner, :validate_implementation_start_transition, 3}},
  # Invokes the injected or default transitioner for implementation startup.
  {:unused_fun, {SymphonyElixir.AgentRunner, :call_implementation_start_transitioner, 3}},
  # Reports a successful implementation-start transition to the orchestrator.
  {:unused_fun, {SymphonyElixir.AgentRunner, :notify_backend_transition, 4}},
  # Executes issue Codex turns and their bounded continuation loop.
  {:unused_fun, {SymphonyElixir.AgentRunner, :do_run_codex_turns, 8}},
  # Supplies workflow state policy to the retained continuation loop.
  {:unused_fun, {SymphonyElixir.AgentRunner, :continuation_settings, 1}},
  # Builds initial and continuation prompts for retained issue turns.
  {:unused_fun, {SymphonyElixir.AgentRunner, :build_turn_prompt, 4}},
  # Starts the app-server initialize handshake before a thread is created.
  {:unused_fun, {SymphonyElixir.Codex.AppServer, :send_initialize, 2}},
  # Connects successful session policy resolution to initialization and thread startup.
  {:unused_fun, {SymphonyElixir.Codex.AppServer, :do_start_session, 4}},
  # Creates the Codex thread used by every successful app-server session.
  {:unused_fun, {SymphonyElixir.Codex.AppServer, :start_thread, 4}},
  # Waits for initialize and thread-start responses during session startup.
  {:unused_fun, {SymphonyElixir.Codex.AppServer, :await_startup_response, 4}},
  # Implements the timeout-aware receive loop for retained startup requests.
  {:unused_fun, {SymphonyElixir.Codex.AppServer, :with_timeout_startup_response, 7}},
  # Classifies each protocol line received by the startup response loop.
  {:unused_fun, {SymphonyElixir.Codex.AppServer, :handle_startup_response, 7}},
  # Preserves startup diagnostics across malformed output and timeouts.
  {:unused_fun, {SymphonyElixir.Codex.AppServer, :append_startup_output, 2}}
]

# Dialyxir 1.4 evaluates this file as Elixir and matches the returned file/description
# terms against its short-format warnings.
Enum.map(unused_functions, fn
  {:unused_fun, {SymphonyElixir.AgentRunner, function, arity}} ->
    {"lib/symphony_elixir/agent_runner.ex",
     "Function #{function}/#{arity} will never be called."}

  {:unused_fun, {SymphonyElixir.Codex.AppServer, function, arity}} ->
    {"lib/symphony_elixir/codex/app_server.ex",
     "Function #{function}/#{arity} will never be called."}
end)

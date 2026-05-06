# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## Fork Status

This repository has diverged from the upstream OpenAI Symphony preview. The original upstream
project is an experimental reference implementation. This fork is now a persistent Phoenix Web
service with SQLite-backed configuration, optional username/password authentication, workflow
versioning, Linear diagnostics, worker/task management views, and an external worker HTTP API.

When reading upstream documentation or comparing behavior with `openai/symphony`, assume this fork
may intentionally differ in runtime configuration, dashboard behavior, persistence, and setup
commands.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run this fork's Elixir-based Symphony implementation. For a direct operator guide, see
[elixir/docs/user_guide.zh-CN.md](elixir/docs/user_guide.zh-CN.md).

You can also ask your favorite coding agent to help with the setup:

> Set up Symphony for my repository based on
> this repository's `elixir/README.md` and `elixir/docs/user_guide.zh-CN.md`

## Local Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): high-level architecture.
- [CODE_STRUCTURE.md](CODE_STRUCTURE.md): code structure overview.
- [CODE_STRUCTURE.zh-CN.md](CODE_STRUCTURE.zh-CN.md): Chinese code structure overview.
- [elixir/docs/user_guide.zh-CN.md](elixir/docs/user_guide.zh-CN.md): installation and startup guide.
- [elixir/docs/long_term_direction.zh-CN.md](elixir/docs/long_term_direction.zh-CN.md): long-term development direction.
- [elixir/docs/persistence_and_auth.md](elixir/docs/persistence_and_auth.md): SQLite and authentication notes.
- [elixir/docs/worker_panel_decoupling_design.zh-CN.md](elixir/docs/worker_panel_decoupling_design.zh-CN.md): worker API and Panel/worker split design.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

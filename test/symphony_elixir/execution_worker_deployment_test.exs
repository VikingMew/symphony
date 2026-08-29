defmodule SymphonyElixir.ExecutionWorkerDeploymentTest do
  use ExUnit.Case, async: true

  @compose Path.expand("../../compose.yaml", __DIR__)
  @dockerfile Path.expand("../../Dockerfile", __DIR__)
  @mise Path.expand("../../mise.toml", __DIR__)
  @publish_workflow Path.expand("../../.github/workflows/publish-image.yml", __DIR__)

  test "shared Codex stage installs the exact supported version" do
    dockerfile = File.read!(@dockerfile)

    assert dockerfile =~ "ARG CODEX_VERSION=0.150.1"
    assert dockerfile =~ ~s(npm install --global "@openai/codex@${CODEX_VERSION}")
    assert dockerfile =~ "FROM toolchain AS worker"
    assert dockerfile =~ "FROM toolchain AS symphony"
    assert length(Regex.scan(~r/COPY --from=codex \/usr\/local\/lib\/node_modules/, dockerfile)) == 3
    refute dockerfile =~ "npm install --global @openai/codex\n"
  end

  test "all Codex targets inherit one pinned mise-managed Elixir toolchain" do
    dockerfile = File.read!(@dockerfile)
    mise = File.read!(@mise)

    assert dockerfile =~ "ARG ELIXIR_IMAGE=elixir:1.19.5-otp-28-slim"
    assert dockerfile =~ "ARG MISE_VERSION=2025.8.16"
    assert dockerfile =~ "FROM ${ELIXIR_IMAGE} AS toolchain"

    assert dockerfile =~
             ~s("https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${mise_arch}.tar.gz")

    assert dockerfile =~
             "tar --extract --gzip --directory /usr/local/bin --strip-components=2 mise/bin/mise"

    assert dockerfile =~ "mise link erlang@28 /usr/local"
    assert dockerfile =~ "mise link elixir@1.19.5-otp-28 /usr/local"
    assert mise =~ ~s(erlang = "28")
    assert mise =~ ~s(elixir = "1.19.5-otp-28")

    for stage <- ["worker", "symphony", "execution-worker"] do
      assert dockerfile =~ "FROM toolchain AS #{stage}"
      body = stage_body(dockerfile, stage)
      assert body =~ "MIX_HOME="
      assert body =~ "HEX_HOME="
      assert body =~ "MISE_CACHE_DIR="
    end

    refute dockerfile =~ ~r/mise[^\n]*(?:latest|releases\/latest)/i
  end

  test "publication CI statically owns non-root read-only toolchain smoke" do
    workflow = File.read!(@publish_workflow)

    for target <- ["symphony", "worker", "execution-worker"] do
      assert workflow =~ "--target #{target}"
      assert workflow =~ "symphony-toolchain:#{target}"
    end

    assert workflow =~ "command -v mise"
    assert workflow =~ "command -v mix"
    assert workflow =~ "command -v elixir"
    assert workflow =~ "command -v erl"
    assert workflow =~ "command -v make"
    assert workflow =~ "--read-only"
    assert workflow =~ "--user 10002:10002"
    assert workflow =~ "mise exec -- mix --version"
    assert workflow =~ "make all"
  end

  test "symphony image configures token-free GitHub credentials at system scope" do
    dockerfile = File.read!(@dockerfile)
    compose = File.read!(@compose)

    assert dockerfile =~
             "git config --system credential.https://github.com.helper '!gh auth git-credential'"

    assert dockerfile =~
             "git config --system url.https://github.com/.insteadOf 'git@github.com:'"

    refute dockerfile =~ "x-access-token"
    refute dockerfile =~ ~r/git config.*\$(?:GH_TOKEN|GITHUB_TOKEN)/
    refute compose =~ "GIT_CONFIG_GLOBAL"
  end

  test "trusted HTTP worker is opt-in, isolated, and non-privileged" do
    compose = File.read!(@compose)
    worker = compose |> String.split("  execution-worker:\n", parts: 2) |> List.last()
    worker = worker |> String.split("\nvolumes:\n", parts: 2) |> List.first()

    assert worker =~ ~s(profiles: ["execution-worker"])
    assert worker =~ "target: execution-worker"
    assert worker =~ "SYMPHONY_ROLE: worker"
    assert worker =~ "SYMPHONY_PANEL_URL: http://symphony:4000"
    assert worker =~ "SYMPHONY_WORKER_TOKEN: ${SYMPHONY_WORKER_REGISTRATION_TOKEN:-}"
    assert worker =~ "read_only: true"
    assert worker =~ "no-new-privileges:true"
    assert worker =~ "cap_drop:\n      - ALL"
    assert worker =~ "execution_worker_workspaces:/worker/workspaces"
    assert worker =~ "execution_worker_cache:/worker/cache"
    assert worker =~ "execution_worker_logs:/worker/logs"
    assert worker =~ "- worker_control\n      - worker_egress"
    refute worker =~ "DATABASE_URL"
    refute worker =~ "POSTGRES_"
    refute worker =~ "LINEAR_API_KEY"
    refute worker =~ "- database"
  end

  test "Compose application services have no container control plane" do
    compose = File.read!(@compose)

    for service <- ["migrate", "symphony", "execution-worker"] do
      body = service_body(compose, service)

      assert body =~ "read_only: true", "#{service} must keep a read-only filesystem"
      assert body =~ "no-new-privileges:true", "#{service} must keep no-new-privileges"
      assert body =~ "cap_drop:\n      - ALL", "#{service} must drop all capabilities"
      refute body =~ ~r/^\s*privileged:\s*true\s*$/m
      refute body =~ "/var/run/docker.sock"
      refute body =~ "/run/docker.sock"
      refute body =~ ~r/(?:podman|containerd|nerdctl).*\.sock/i
    end
  end

  test "Panel and execution worker runtime stages do not install container-engine CLIs" do
    dockerfile = File.read!(@dockerfile)

    for stage <- ["toolchain", "worker", "symphony", "execution-worker"] do
      body = stage_body(dockerfile, stage)

      refute body =~ ~r/^\s*(?:docker(?:-\S+)?|buildx|podman(?:-\S+)?|nerdctl)\s*\\?\s*$/mi
      refute body =~ ~r/^\s*(?:COPY|ADD)\s+.*(?:docker|buildx|podman|nerdctl)/mi
    end
  end

  test "image and source identity are required and example values are exact" do
    compose = File.read!(@compose)
    env = File.read!(Path.expand("../../.env.example", __DIR__))

    assert compose =~ ~r/SYMPHONY_EXECUTION_WORKER_IMAGE:-\S+:[0-9a-f]{40}/
    assert compose =~ ~r/SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION:-[0-9a-f]{40}/
    assert env =~ ~r/SYMPHONY_EXECUTION_WORKER_IMAGE=\S+:[0-9a-f]{40}\n/
    assert env =~ ~r/SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=[0-9a-f]{40}\n/
  end

  defp service_body(compose, service) do
    compose
    |> String.split("  #{service}:\n", parts: 2)
    |> List.last()
    |> String.split(~r/^  [a-zA-Z0-9_-]+:\n/m, parts: 2)
    |> List.first()
  end

  defp stage_body(dockerfile, stage) do
    dockerfile
    |> String.split(~r/^FROM .* AS #{Regex.escape(stage)}\s*$/m, parts: 2)
    |> List.last()
    |> String.split(~r/^FROM /m, parts: 2)
    |> List.first()
  end
end

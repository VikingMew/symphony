defmodule SymphonyElixir.ExecutionWorkerDeploymentTest do
  use ExUnit.Case, async: true

  @compose Path.expand("../../compose.yaml", __DIR__)
  @dockerfile Path.expand("../../Dockerfile", __DIR__)
  @mise Path.expand("../../mise.toml", __DIR__)
  @publish_workflow Path.expand("../../.github/workflows/publish-image.yml", __DIR__)
  @published_compose Path.expand("../../compose.published.yaml", __DIR__)
  @worker_compose Path.expand("../../compose.worker.yaml", __DIR__)
  @quality_workflow Path.expand("../../.github/workflows/make-all.yml", __DIR__)

  test "shared Codex stage installs the exact supported version" do
    dockerfile = File.read!(@dockerfile)

    assert dockerfile =~ "ARG CODEX_VERSION=0.150.1"
    assert dockerfile =~ ~s(npm install --global "@openai/codex@${CODEX_VERSION}")
    assert dockerfile =~ "FROM toolchain AS worker"
    assert dockerfile =~ "FROM toolchain AS symphony-base"
    assert dockerfile =~ "FROM symphony-${SYMPHONY_EMBED_CODEX} AS symphony"
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

    for stage <- ["worker", "symphony-base", "execution-worker"] do
      assert dockerfile =~ "FROM toolchain AS #{stage}"
      body = stage_body(dockerfile, stage)
      assert body =~ "MIX_HOME="
      assert body =~ "HEX_HOME="
      assert body =~ "MISE_CACHE_DIR="
      assert body =~ "XDG_CACHE_HOME="
    end

    refute dockerfile =~ ~r/mise[^\n]*(?:latest|releases\/latest)/i
  end

  test "publication CI statically owns non-root read-only toolchain smoke" do
    workflow = File.read!(@publish_workflow)
    compose = File.read!(@compose)

    for target <- ["symphony", "worker", "execution-worker"] do
      assert workflow =~ "--target #{target}"
      assert workflow =~ "symphony-toolchain:#{target}"
    end

    assert workflow =~ "command -v mise"
    assert workflow =~ "command -v mix"
    assert workflow =~ "command -v elixir"
    assert workflow =~ "command -v erl"
    assert workflow =~ "command -v make"
    assert length(Regex.scan(~r/command -v gh/, workflow)) == 3

    assert length(
             Regex.scan(
               ~r/git config --system --get-all credential\.https:\/\/github\.com\.helper/,
               workflow
             )
           ) == 3

    assert length(
             Regex.scan(
               ~r/git config --system --get-all url\.https:\/\/github\.com\/\.insteadOf/,
               workflow
             )
           ) == 3

    refute workflow =~ "git credential fill"
    assert workflow =~ "--read-only"
    assert workflow =~ "--user 10002:10002"
    assert workflow =~ "--tmpfs /tmp:rw,exec,mode=1777"
    assert workflow =~ "--tmpfs /worker/cache:rw,exec,mode=1777"
    assert workflow =~ "--tmpfs /worker/workspaces:rw,exec,mode=1777"
    assert workflow =~ "mise exec -- mix --version"
    refute workflow =~ "scripts/check.sh"
    assert workflow =~ "mix format --check-formatted"
    assert workflow =~ "Formatting: drift detected"
    assert workflow =~ "needs: [quality-gate, publish]"
    assert workflow =~ "if: always()"
    assert length(Regex.scan(~r/^      - \/tmp:exec,mode=1777$/m, compose)) == 2
  end

  test "blocking quality workflow owns repository aggregate" do
    quality = File.read!(@quality_workflow)
    assert quality =~ "scripts/check.sh"
  end

  test "all Codex images configure token-free GitHub credentials at system scope" do
    dockerfile = File.read!(@dockerfile)
    compose = File.read!(@compose)

    for stage <- ["worker", "symphony-base", "execution-worker"] do
      body = stage_body(dockerfile, stage)

      assert body =~ ~r/^\s*gh \\?$/m, "#{stage} must install gh"

      assert body =~
               "git config --system credential.https://github.com.helper '!gh auth git-credential'"

      assert body =~
               "git config --system url.https://github.com/.insteadOf 'git@github.com:'"

      refute body =~ "x-access-token"
      refute body =~ ~r/git config.*\$(?:GH_TOKEN|GITHUB_TOKEN)/
    end

    refute compose =~ ~r/GIT_CONFIG_(?:GLOBAL|COUNT|KEY|VALUE)/
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
    assert worker =~ "execution_worker_codex:/home/symphony/.codex"
    assert worker =~ "- worker_control\n      - worker_egress"
    refute worker =~ "DATABASE_URL"
    refute worker =~ "POSTGRES_"
    assert worker =~ "LINEAR_API_KEY"
    refute worker =~ "- database"
  end

  test "Panel image branches Codex ownership at build time" do
    dockerfile = File.read!(@dockerfile)
    compose = File.read!(@compose)
    workflow = File.read!(@publish_workflow)

    assert dockerfile =~ "ARG SYMPHONY_EMBED_CODEX=true"
    assert dockerfile =~ "FROM symphony-base AS symphony-false"
    assert dockerfile =~ "FROM symphony-base AS symphony-true"
    assert dockerfile =~ "FROM symphony-${SYMPHONY_EMBED_CODEX} AS symphony"

    codex_panel = stage_body(dockerfile, "symphony-true")
    control_panel = stage_body(dockerfile, "symphony-false")
    assert codex_panel =~ "ENV CODEX_HOME=/home/symphony/.codex"
    assert codex_panel =~ "COPY --from=codex /usr/local/bin/node"
    assert codex_panel =~ "COPY --from=codex /usr/local/lib/node_modules"
    assert codex_panel =~ ~s(VOLUME ["/home/symphony/.codex"])
    refute control_panel =~ "CODEX_HOME"
    refute control_panel =~ "--from=codex"
    refute control_panel =~ "/home/symphony/.codex"

    for service <- ["migrate", "symphony"] do
      assert service_body(compose, service) =~ ~s(SYMPHONY_EMBED_CODEX: "true")
    end

    assert workflow =~ "docker build --build-arg SYMPHONY_EMBED_CODEX=false --target symphony"
    assert workflow =~ "SYMPHONY_EMBED_CODEX=false"
    assert workflow =~ "! command -v codex"
    assert workflow =~ ~s(test -z "${CODEX_HOME:-}")
  end

  test "published worker-mode Panel has no Codex credential mount" do
    compose = File.read!(@published_compose)
    panel = service_body(compose, "symphony")

    assert panel =~ "SYMPHONY_EXECUTION_MODE: worker"
    assert panel =~ "volumes: !override"
    refute panel =~ "codex_home"
    assert panel =~ "gh_config:/home/symphony/.config/gh"

    worker = service_body(File.read!(@compose), "execution-worker")
    assert worker =~ "execution_worker_codex:/home/symphony/.codex"
  end

  test "local worker-mode Compose selects the control-only Panel" do
    compose = File.read!(@worker_compose)

    for service <- ["migrate", "symphony"] do
      assert service_body(compose, service) =~ ~s(SYMPHONY_EMBED_CODEX: "false")
    end

    panel = service_body(compose, "symphony")
    assert panel =~ "SYMPHONY_EXECUTION_MODE: worker"
    assert panel =~ "volumes: !override"
    refute panel =~ "codex_home"
  end

  test "deployment docs state Codex binary and credential ownership" do
    compose_doc = File.read!(Path.expand("../../docs/compose.md", __DIR__))
    operations = File.read!(Path.expand("../../docs/execution-worker-operations.md", __DIR__))
    alignment = File.read!(Path.expand("../../docs/documentation-alignment.md", __DIR__))

    for doc <- [compose_doc, operations, alignment] do
      assert doc =~ "SYMPHONY_EMBED_CODEX=false"
      assert doc =~ "execution_worker_codex"
      assert doc =~ "control-only"
    end

    assert compose_doc =~ "default local `symphony` build is the centralized Panel"
    assert operations =~ "default local centralized Panel remains"
    assert alignment =~ "contains neither Codex/Node nor `CODEX_HOME`"
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

  test "publication workflow publishes the execution worker image" do
    workflow = File.read!(@publish_workflow)

    assert workflow =~ "WORKER_IMAGE: ghcr.io/vikingmew/symphony-execution-worker"
    assert workflow =~ "target: execution-worker"
    assert workflow =~ "platforms: linux/amd64,linux/arm64"
    assert workflow =~ "worker_tags=\"${WORKER_IMAGE}:sha-${GITHUB_SHA}\""
    assert workflow =~ "${WORKER_IMAGE}:latest"
    assert workflow =~ "worker_release_tag=\"${WORKER_IMAGE}:${GITHUB_REF_NAME}\""
    assert workflow =~ "Inspect worker manifest platforms"
    assert workflow =~ "Smoke published worker on both platforms"
  end

  test "published Compose validation quotes the execution worker service key" do
    workflow = File.read!(@publish_workflow)

    assert workflow =~
             "docker compose -f compose.yaml -f compose.published.yaml --profile execution-worker config --format json"

    assert workflow =~ ~r/\.services\["execution-worker"\]\.image == env\.SYMPHONY_EXECUTION_WORKER_IMAGE/
    assert workflow =~ ~r/\.services\["execution-worker"\] \| has\("build"\)/
    assert workflow =~ ~r/\.services\["execution-worker"\]\.pull_policy == "always"/
    assert workflow =~ ~r/\.services\["execution-worker"\]\.profiles == \["execution-worker"\]/
    refute workflow =~ ".services.execution-worker"
  end

  test "published Compose removes the worker build and requires its image" do
    compose = File.read!(@published_compose)
    worker = service_body(compose, "execution-worker")

    assert worker =~ "build: !reset null"
    assert worker =~ "SYMPHONY_EXECUTION_WORKER_IMAGE:?set SYMPHONY_EXECUTION_WORKER_IMAGE"
    assert worker =~ "pull_policy: always"
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

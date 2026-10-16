defmodule SymphonyElixir.DeployScriptTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/deploy.sh", __DIR__)
  @sha String.duplicate("a", 40)

  test "deploy uses the release file set, pulls before mutation, and reads the panel port from .env" do
    fixture = fixture()
    on_exit(fn -> File.rm_rf!(fixture.root) end)
    write_fake_tools(fixture)

    {output, status} = run_script(fixture, "deploy")
    assert status == 0, output
    assert output =~ "images: same sha"
    assert output =~ "migrations: current"
    assert output =~ "worker session: online"
    assert output =~ "pins: current"
    assert output =~ "manually enable listening"

    calls = File.read!(fixture.recorder)
    assert calls =~ "compose -f"
    assert calls =~ "compose.yaml -f " <> Path.expand("compose.worker-release.yaml")
    assert calls =~ "-f " <> Path.expand("compose.host-override.yaml")
    assert calls =~ "--profile execution-worker"
    assert calls =~ "pull symphony execution-worker"
    assert calls =~ "exec -T postgres pg_dump --format=custom"
    assert calls =~ "run --rm --no-build migrate"
    assert calls =~ "up -d --no-build symphony execution-worker"
    assert index(calls, " pull ") < index(calls, " exec -T postgres")
    assert index(calls, " exec -T postgres") < index(calls, " run --rm --no-build")
    assert index(calls, " run --rm --no-build") < index(calls, " up -d --no-build")
    refute calls =~ ~r/compose .* pull .* after migration/s

    env = File.read!(fixture.env)
    assert env =~ "SYMPHONY_IMAGE=ghcr.io/vikingmew/symphony:sha-#{@sha}"
    assert env =~ "SYMPHONY_EXECUTION_WORKER_IMAGE=ghcr.io/vikingmew/symphony-execution-worker:sha-#{@sha}"
    assert env =~ "SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=#{@sha}"
    refute File.exists?(Path.join(fixture.root, "backups"))
  end

  test "check returns nonzero and reports actual values when the worker drifts" do
    fixture = fixture()
    on_exit(fn -> File.rm_rf!(fixture.root) end)
    write_fake_tools(fixture)

    File.write!(
      fixture.env,
      File.read!(fixture.env) <>
        "SYMPHONY_IMAGE=ghcr.io/vikingmew/symphony:sha-#{@sha}\nSYMPHONY_EXECUTION_WORKER_IMAGE=ghcr.io/vikingmew/symphony-execution-worker:sha-#{@sha}\nSYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=#{@sha}\n"
    )

    {output, status} = run_script(fixture, "check", %{"FAKE_WORKER_IMAGE" => "ghcr.io/vikingmew/symphony-execution-worker:sha-#{String.duplicate("b", 40)}"})
    assert status != 0
    assert output =~ "images: drift"
    assert output =~ "target panel=ghcr.io/vikingmew/symphony:sha-#{@sha}"
    assert output =~ "worker actual image: ghcr.io/vikingmew/symphony-execution-worker:sha-#{String.duplicate("b", 40)}"
    assert output =~ "stage: check"
  end

  test "a failed migration stops before the application switch" do
    fixture = fixture()
    on_exit(fn -> File.rm_rf!(fixture.root) end)
    write_fake_tools(fixture)

    {_output, status} = run_script(fixture, "deploy", %{"FAIL_RUN" => "1"})
    assert status != 0
    calls = File.read!(fixture.recorder)
    assert calls =~ "run --rm --no-build migrate"
    refute calls =~ "up -d --no-build symphony execution-worker"
  end

  test "a non-SHA target stops before pulling or mutating deployment state" do
    fixture = fixture()
    on_exit(fn -> File.rm_rf!(fixture.root) end)
    write_fake_tools(fixture)

    env = [{"ENV_FILE", fixture.env}, {"RECORDER", fixture.recorder}, {"PATH", fixture.tools <> ":" <> System.get_env("PATH")}]
    {output, status} = System.cmd("bash", [@script, "deploy", "not-a-sha"], cd: fixture.root, env: env, stderr_to_stdout: true)

    assert status != 0
    assert output =~ "40-character lowercase commit SHA"
    calls = File.read!(fixture.recorder)
    refute calls =~ " pull symphony execution-worker"
    refute calls =~ " exec -T postgres"
    refute calls =~ " run --rm --no-build migrate"
    refute calls =~ " up -d --no-build symphony execution-worker"
  end

  test "the source has no old published filename or pull policy" do
    release = File.read!(Path.expand("../../compose.worker-release.yaml", __DIR__))
    refute release =~ "pull_policy"
    assert File.read!(@script) =~ "compose.worker-release.yaml"
    assert File.read!(@script) =~ "execution-worker"
    assert File.read!(@script) =~ "--no-build"
  end

  defp fixture do
    root = Path.join(System.tmp_dir!(), "symphony-deploy-#{System.unique_integer([:positive])}")
    tools = Path.join(root, "bin")
    File.mkdir_p!(tools)
    env = Path.join(root, ".env")
    recorder = Path.join(root, "calls.log")
    File.write!(env, "POSTGRES_USER=symphony\nPOSTGRES_DB=symphony\nSYMPHONY_DASHBOARD_PORT=4011\nSYMPHONY_EXECUTION_WORKER_CODEX_AUTH_FILE=/tmp/auth.json\n")
    %{root: root, tools: tools, env: env, recorder: recorder}
  end

  defp write_fake_tools(fixture) do
    docker = """
    #!/usr/bin/env bash
    set -u
    printf '%s\\n' "$*" >> "$RECORDER"
    if [[ "$1" == compose ]]; then
      if [[ "$*" == *" pull symphony execution-worker"* ]]; then
        [[ "${FAIL_PULL:-0}" == 1 ]] && exit 41
      elif [[ "$*" == *" exec -T postgres"* ]]; then
        printf 'custom backup'
      elif [[ "$*" == *" ps -q symphony"* ]]; then
        echo panel-id
      elif [[ "$*" == *" ps -q execution-worker"* ]]; then
        echo worker-id
      elif [[ "$*" == *" run --rm --no-build migrate"* ]]; then
        [[ "${FAIL_RUN:-0}" == 1 ]] && exit 42
      fi
      exit 0
    fi
    if [[ "$1" == inspect ]]; then
      if [[ "$*" == *worker-id* ]]; then
        echo "${FAKE_WORKER_IMAGE:-ghcr.io/vikingmew/symphony-execution-worker:sha-#{@sha}}"
      else
        echo "${FAKE_PANEL_IMAGE:-ghcr.io/vikingmew/symphony:sha-#{@sha}}"
      fi
      exit 0
    fi
    exit 0
    """

    curl = """
    #!/usr/bin/env bash
    case "$1" in
      --fail) shift ;;
    esac
    if [[ "$*" == */health/ready* ]]; then
      echo '{"checks":{"migrations":"current"}}'
    else
      echo '<span>online</span>'
    fi
    """

    jq = "#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n"

    for {name, body} <- [{"docker", docker}, {"curl", curl}, {"jq", jq}] do
      path = Path.join(fixture.tools, name)
      File.write!(path, body)
      File.chmod!(path, 0o755)
    end
  end

  defp run_script(fixture, action, extra_env \\ %{}) do
    env = [{"ENV_FILE", fixture.env}, {"RECORDER", fixture.recorder}, {"PATH", fixture.tools <> ":" <> System.get_env("PATH")}]
    env = Enum.reduce(extra_env, env, fn {key, value}, acc -> List.keystore(acc, key, 0, {key, value}) end)

    System.cmd("bash", [@script, action, @sha], cd: fixture.root, env: env, stderr_to_stdout: true)
  end

  defp index(string, needle) do
    case :binary.match(string, needle) do
      {position, _length} -> position
      :nomatch -> flunk("missing #{inspect(needle)} in #{string}")
    end
  end
end

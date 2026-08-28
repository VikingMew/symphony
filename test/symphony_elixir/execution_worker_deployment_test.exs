defmodule SymphonyElixir.ExecutionWorkerDeploymentTest do
  use ExUnit.Case, async: true

  @compose Path.expand("../../compose.yaml", __DIR__)

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

  test "image and source identity are required and example values are exact" do
    compose = File.read!(@compose)
    env = File.read!(Path.expand("../../.env.example", __DIR__))

    assert compose =~ "SYMPHONY_EXECUTION_WORKER_IMAGE:?set an exact execution worker image tag or digest"
    assert compose =~ "SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION:?set the full worker source revision"
    assert env =~ ~r/SYMPHONY_EXECUTION_WORKER_IMAGE=\S+:[0-9a-f]{40}\n/
    assert env =~ ~r/SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=[0-9a-f]{40}\n/
  end
end

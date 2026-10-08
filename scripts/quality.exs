root = Path.expand("..", __DIR__)
File.cd!(root)
started = System.monotonic_time(:millisecond)
run = "#{System.system_time(:microsecond)}-#{System.pid()}"
output = Path.join([root, "_build", "quality", run])
File.mkdir_p!(output)

gates =
  for gate <- ~w(check unit dialyzer) do
    log_path = Path.join(output, "#{gate}.log")
    before = System.monotonic_time(:millisecond)
    {_, code} = System.cmd("bash", ["scripts/#{gate}.sh"], into: File.stream!(log_path), stderr_to_stdout: true, env: [{"CI", "true"}])
    duration = System.monotonic_time(:millisecond) - before
    result = %{gate: gate, status: if(code == 0, do: "passed", else: "failed"), duration: duration, log_path: log_path}

    result =
      if code == 0 do
        result
      else
        Map.merge(result, %{violation: "gate_failed", actual: %{exit_code: code}, expected: %{exit_code: 0}})
      end

    IO.puts(:json.encode(result))
    result
  end

passed = Enum.all?(gates, &(&1.status == "passed"))
summary = %{status: if(passed, do: "passed", else: "failed"), duration: System.monotonic_time(:millisecond) - started, duration_unit: "millisecond", gates: gates}
summary_path = Path.join(output, "summary.json")
File.write!(summary_path, :json.encode(summary))
IO.puts(:json.encode(Map.merge(Map.drop(summary, [:gates]), %{summary_path: summary_path})))
System.halt(if passed, do: 0, else: 1)

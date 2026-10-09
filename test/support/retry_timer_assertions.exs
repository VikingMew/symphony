defmodule SymphonyElixir.TestSupport.RetryTimerAssertions do
  @moduledoc false
  import ExUnit.Assertions

  def trace_retry_timers(pid) do
    :erlang.trace_pattern({:erlang, :send_after, 3}, true, [])
    :erlang.trace_pattern({:erlang, :monotonic_time, 1}, [{[:millisecond], [], [{:return_trace}]}], [])
    :erlang.trace(pid, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      :erlang.trace_pattern({:erlang, :send_after, 3}, false, [])
      :erlang.trace_pattern({:erlang, :monotonic_time, 1}, false, [])
    end)
  end

  def assert_retry_delay(pid, issue_id, retry_entry, expected_ms) do
    message = {:retry_issue, issue_id, retry_entry.retry_token}
    clock_ms = retry_entry.due_at_ms - expected_ms - 400

    assert_receive {:trace, ^pid, :return_from, {:erlang, :monotonic_time, 1}, ^clock_ms}
    assert_receive {:trace, ^pid, :call, {:erlang, :send_after, [^expected_ms, ^pid, ^message]}}
    assert is_reference(retry_entry.timer_ref)
  end
end

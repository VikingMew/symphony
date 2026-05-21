defmodule SymphonyElixir.ShellTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Shell

  test "escapes POSIX shell values with single quotes" do
    assert Shell.escape("") == "''"
    assert Shell.escape("simple") == "'simple'"
    assert Shell.escape("/tmp/path with spaces") == "'/tmp/path with spaces'"
    assert Shell.escape("it's fine") == "'it'\"'\"'s fine'"
  end
end

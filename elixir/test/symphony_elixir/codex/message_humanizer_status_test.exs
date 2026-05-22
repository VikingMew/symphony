defmodule SymphonyElixir.Codex.MessageHumanizerStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.MessageHumanizer

  test "status dashboard strips ANSI and control bytes from codex messages" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    plain = MessageHumanizer.humanize_codex_message(payload)

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end
end

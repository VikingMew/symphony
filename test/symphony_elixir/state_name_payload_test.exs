defmodule SymphonyElixir.StateNamePayloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Payload, StateName, Text}

  test "normalizes state names and blank string semantics" do
    assert StateName.normalize(" In Progress ") == "in progress"
    assert StateName.normalize(nil) == ""
    assert StateName.blank_string?(nil)
    assert StateName.blank_string?("  ")
    refute StateName.blank_string?(:atom)
  end

  test "reads mixed atom and string keyed payloads" do
    payload = %{"phase" => "workspace", nested: %{"status" => "started"}}

    assert Payload.get_any(payload, [:phase, "phase"]) == "workspace"
    assert Payload.get_path(payload, [[:nested, "nested"], [:status, "status"]]) == "started"
    assert Payload.get_any(%{}, [:missing], "fallback") == "fallback"
    assert Payload.get_any(nil, [:missing], "fallback") == "fallback"
    assert Payload.get_path(%{}, [[:missing], [:status]], "fallback") == "fallback"
  end

  test "shared text blank helpers support strict and form-style blank checks" do
    assert Text.blank?(nil)
    assert Text.blank?("  ")
    refute Text.blank?(:atom)

    assert Text.blankish?(nil)
    assert Text.blankish?("  ")
    refute Text.blankish?(:atom)
    assert Text.blank_as_nil("  ") == nil
    assert Text.blank_as_nil(:value) == "value"
  end
end

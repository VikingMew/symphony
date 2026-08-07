defmodule SymphonyElixir.NumberFormatTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.NumberFormat

  test "formats integer groups for dashboard presentation" do
    assert NumberFormat.grouped_integer(0) == "0"
    assert NumberFormat.grouped_integer(123) == "123"
    assert NumberFormat.grouped_integer(1_234_567) == "1,234,567"
    assert NumberFormat.grouped_integer(-1_234_567) == "-1,234,567"
  end
end

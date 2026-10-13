defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use SymphonyElixir.Config.Schema.Sections.Types
  use SymphonyElixir.Config.Schema.Sections.Parsing
  use SymphonyElixir.Config.Schema.Sections.Defaults
end

Path.join(__DIR__, "fake_persistence_sections/*.exs")
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)

defmodule SymphonyElixir.TestSupport.FakePersistence do
  use SymphonyElixir.TestSupport.FakePersistence.Sections.FakePersistence1
  use SymphonyElixir.TestSupport.FakePersistence.Sections.FakePersistence2
end

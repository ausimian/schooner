defmodule SchoonerTest do
  use ExUnit.Case
  doctest Schooner

  test "greets the world" do
    assert Schooner.hello() == :world
  end
end

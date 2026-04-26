defmodule Schooner.ReaderPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Schooner.Reader
  alias Schooner.Test.ValueGenerators
  alias Schooner.Value

  property "write/read round-trip on readable values" do
    check all(v <- ValueGenerators.readable_value()) do
      written = Value.write(v)
      assert [read_back] = Reader.read_string(written)
      assert Value.equal?(v, read_back)
    end
  end

  property "wrapping a readable value in a list still round-trips" do
    check all(v <- ValueGenerators.readable_value(2)) do
      list = Value.list([v])
      written = Value.write(list)
      assert [read_back] = Reader.read_string(written)
      assert Value.equal?(list, read_back)
    end
  end
end

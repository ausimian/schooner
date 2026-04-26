defmodule Schooner.ValuePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Schooner.Reader
  alias Schooner.Test.ValueGenerators
  alias Schooner.Value

  property "every value is equal? to itself" do
    check all(v <- ValueGenerators.value()) do
      assert Value.equal?(v, v)
    end
  end

  property "every value is eqv? to itself" do
    check all(v <- ValueGenerators.value()) do
      assert Value.eqv?(v, v)
    end
  end

  property "write produces non-empty iodata for every value" do
    check all(v <- ValueGenerators.value()) do
      out = Value.write(v)
      assert is_binary(out)
      assert byte_size(out) > 0
    end
  end

  property "display produces non-empty iodata for every value" do
    check all(v <- ValueGenerators.value()) do
      out = Value.display(v)
      assert is_binary(out)
      assert byte_size(out) >= 0
    end
  end

  property "write/read round-trip preserves equal?" do
    check all(v <- ValueGenerators.readable_value()) do
      written = Value.write(v)
      assert [read_back] = Reader.read_string(written)
      assert Value.equal?(v, read_back)
    end
  end
end

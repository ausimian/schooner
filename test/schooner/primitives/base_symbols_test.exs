defmodule Schooner.Primitives.BaseSymbolsTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run!(source)

  describe "symbol identity" do
    test "two string->symbol calls on the same string are eq?" do
      assert run(~S|(eq? (string->symbol "foo") (string->symbol "foo"))|) ==
               Value.bool(true)
    end

    test "symbol=? on equal symbols" do
      assert run("(symbol=? 'a 'a)") == Value.bool(true)
      assert run("(symbol=? 'a 'a 'a)") == Value.bool(true)
      assert run("(symbol=? 'a 'b)") == Value.bool(false)
    end

    test "symbol=? rejects non-symbols" do
      e = assert_raise PError, fn -> run(~S|(symbol=? 'a "a")|) end
      assert match?({:type_error, "symbol=?", "symbol", _}, e.reason)
    end
  end

  describe "symbol/string conversion" do
    test "symbol->string" do
      assert run("(symbol->string 'hello)") == Value.string("hello")
    end

    test "string->symbol" do
      assert run(~S|(string->symbol "hello")|) == Value.symbol("hello")
    end

    test "round-trip" do
      assert run(~S|(symbol->string (string->symbol "x y"))|) == Value.string("x y")
    end

    test "type errors" do
      e = assert_raise PError, fn -> run(~S|(symbol->string "not-a-symbol")|) end
      assert match?({:type_error, "symbol->string", "symbol", _}, e.reason)

      e = assert_raise PError, fn -> run("(string->symbol 'not-a-string)") end
      assert match?({:type_error, "string->symbol", "string", _}, e.reason)
    end
  end
end

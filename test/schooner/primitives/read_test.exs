defmodule Schooner.Primitives.ReadTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run!(source)

  describe "read" do
    test "reads an integer" do
      assert run(~S|(read "42")|) == 42
    end

    test "reads a list" do
      assert run(~S|(read "(1 2 3)")|) == Value.list([1, 2, 3])
    end

    test "reads a quoted form" do
      assert run(~S|(read "'foo")|) ==
               Value.list([Value.symbol("quote"), Value.symbol("foo")])
    end

    test "returns eof on empty input" do
      assert run(~S|(read "")|) == :eof
      assert run(~S|(read "   ")|) == :eof
    end

    test "first datum from a multi-datum string" do
      assert run(~S|(read "1 2 3")|) == 1
    end

    test "round-trips through write" do
      assert run(~S|(read (write '(1 2 3)))|) == Value.list([1, 2, 3])
    end

    test "raises type error on non-string argument" do
      e = assert_raise PError, fn -> run("(read 42)") end
      assert match?({:type_error, "read", "string", _}, e.reason)
    end
  end
end

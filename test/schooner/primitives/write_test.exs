defmodule Schooner.Primitives.WriteTest do
  use ExUnit.Case, async: true

  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run!(source)

  describe "write" do
    test "renders strings with quotes" do
      assert run(~S|(write "hi")|) == Value.string("\"hi\"")
    end

    test "renders booleans" do
      assert run("(write #t)") == Value.string("#t")
      assert run("(write #f)") == Value.string("#f")
    end

    test "renders integers and floats" do
      assert run("(write 42)") == Value.string("42")
      assert run("(write 1.5)") == Value.string("1.5")
    end

    test "renders symbols and lists" do
      assert run("(write 'foo)") == Value.string("foo")
      assert run("(write '(1 2 3))") == Value.string("(1 2 3)")
    end

    test "renders the empty list" do
      assert run("(write '())") == Value.string("()")
    end
  end

  describe "display" do
    test "renders strings without quotes" do
      assert run(~S|(display "hi")|) == Value.string("hi")
    end

    test "renders chars as their literal codepoint" do
      assert run(~S|(display #\a)|) == Value.string("a")
    end
  end

  describe "write-shared / write-simple" do
    test "delegate to write for cycle-free immutable values" do
      assert run(~S|(write-shared "hi")|) == Value.string("\"hi\"")
      assert run("(write-simple '(1 2))") == Value.string("(1 2)")
    end
  end

  describe "newline" do
    test "returns the literal newline string" do
      assert run("(newline)") == Value.string("\n")
    end

    test "errors when given an argument" do
      assert_raise EvalError, fn -> run("(newline 'extra)") end
    end
  end

  describe "write-string" do
    test "returns the input string unchanged" do
      assert run(~S|(write-string "hello")|) == Value.string("hello")
      assert run(~S|(write-string "")|) == Value.string("")
    end

    test "rejects non-string input" do
      e = assert_raise PError, fn -> run("(write-string 42)") end
      assert match?({:type_error, "write-string", "string", _}, e.reason)
    end
  end

  describe "arity" do
    test "write/1 errors with too many arguments" do
      assert_raise EvalError, fn -> run(~S|(write "a" "b")|) end
    end
  end
end

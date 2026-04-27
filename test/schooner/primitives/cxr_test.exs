defmodule Schooner.Primitives.CxrTest do
  use ExUnit.Case, async: true

  alias Schooner.Library
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "depth-2 accessors" do
    test "caar / cadr / cdar / cddr" do
      assert run("(caar '((1 2) (3 4)))") === 1
      assert run("(cadr '(1 2 3))") === 2
      assert run("(cdar '((1 2) 3))") == Value.list([2])
      assert run("(cddr '(1 2 3 4))") == Value.list([3, 4])
    end
  end

  describe "depth-3 accessors" do
    test "caddr selects the third element" do
      assert run("(caddr '(1 2 3 4))") === 3
    end

    test "cadar selects via mixed walks" do
      # cadar = car (cdr (car x))) — second element of the first list.
      assert run("(cadar '((10 20 30) (40 50 60)))") === 20
    end
  end

  describe "depth-4 accessors" do
    test "cadddr selects the fourth element" do
      assert run("(cadddr '(1 2 3 4 5))") === 4
    end

    test "cddddr drops the first four" do
      assert run("(cddddr '(1 2 3 4 5 6))") == Value.list([5, 6])
    end
  end

  describe "type errors" do
    test "applying caar to a non-pair raises" do
      e = assert_raise PError, fn -> run("(caar '())") end
      assert match?({:type_error, "caar", "pair", _}, e.reason)
    end

    test "applying caddr to a list shorter than 3 raises" do
      e = assert_raise PError, fn -> run("(caddr '(1 2))") end
      assert match?({:type_error, "caddr", "pair", _}, e.reason)
    end
  end

  describe "registration completeness" do
    test "every depth-2/3/4 c..r name is registered" do
      depth2 = for a <- ["a", "d"], b <- ["a", "d"], do: "c" <> a <> b <> "r"

      depth3 =
        for a <- ["a", "d"], b <- ["a", "d"], c <- ["a", "d"], do: "c" <> a <> b <> c <> "r"

      depth4 =
        for a <- ["a", "d"],
            b <- ["a", "d"],
            c <- ["a", "d"],
            d <- ["a", "d"],
            do: "c" <> a <> b <> c <> d <> "r"

      %{exports: cxr_exports} =
        Library.fetch!(Library.standard(), ["scheme", "cxr"])

      for name <- depth2 ++ depth3 ++ depth4 do
        assert {:var, {:primitive, ^name, 1, _}} = Map.fetch!(cxr_exports, name)
      end
    end
  end
end

defmodule Schooner.Primitives.CaseLambdaTest do
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "clause shapes" do
    test "empty fixed-arity formals" do
      assert run("((case-lambda (() 'zero))) ") == Value.symbol("zero")
    end

    test "single fixed-arity clause" do
      assert run("((case-lambda ((x) (* x 2))) 21)") == 42
    end

    test "multi-element fixed-arity clause" do
      assert run("((case-lambda ((x y z) (+ x y z))) 1 2 3)") == 6
    end

    test "rest-only (variadic) formals bind the args list" do
      assert run("((case-lambda (xs xs)) 1 2 3)") ==
               Value.list([1, 2, 3])
    end

    test "rest-only formals also accept zero args" do
      assert run("((case-lambda (xs xs)))") == :null
    end

    test "dotted-rest formals bind the head positionally and the tail as a list" do
      assert run("((case-lambda ((a b . rest) (list a b rest))) 1 2 3 4)") ==
               Value.list([1, 2, Value.list([3, 4])])
    end

    test "dotted-rest with empty tail still matches the at-least arity" do
      assert run("((case-lambda ((a b . rest) (list a b rest))) 10 20)") ==
               Value.list([10, 20, :null])
    end
  end

  describe "arity selection" do
    test "selects the matching fixed-arity clause" do
      source = """
      (define f
        (case-lambda
          (() 'zero)
          ((x) (list 'one x))
          ((x y) (list 'two x y))))
      (list (f) (f 1) (f 1 2))
      """

      assert run(source) ==
               Value.list([
                 Value.symbol("zero"),
                 Value.list([Value.symbol("one"), 1]),
                 Value.list([Value.symbol("two"), 1, 2])
               ])
    end

    test "first matching clause wins; later clauses with same arity are dead" do
      source = """
      (define f
        (case-lambda
          ((x) 'first)
          ((x) 'second)))
      (f 99)
      """

      assert run(source) == Value.symbol("first")
    end

    test "dotted-rest clause covers any arity at-or-above its fixed prefix" do
      source = """
      (define f
        (case-lambda
          (() 0)
          ((a . rest) (+ a (length rest)))))
      (list (f) (f 10) (f 10 'a 'b 'c))
      """

      assert run(source) == Value.list([0, 10, 13])
    end
  end

  describe "no matching clause" do
    test "raises a Scheme error tagged 'case-lambda: no matching clause'" do
      source = """
      (define f
        (case-lambda
          ((x) x)
          ((x y) (+ x y))))
      (f 1 2 3)
      """

      e = assert_raise Schooner.Error, fn -> run(source) end
      assert {:error_obj, :user, {:string, msg}, [args]} = e.value
      assert msg == "case-lambda: no matching clause"
      assert args == Value.list([1, 2, 3])
    end

    test "(case-lambda) with zero clauses errors on every call" do
      e = assert_raise Schooner.Error, fn -> run("((case-lambda) 1)") end
      assert {:error_obj, :user, {:string, "case-lambda: no matching clause"}, _} = e.value
    end
  end

  describe "nested case-lambda inside another lambda" do
    test "closes over the outer lambda's parameter" do
      source = """
      (define mk
        (lambda (base)
          (case-lambda
            (() base)
            ((delta) (+ base delta))
            ((lo hi) (+ base lo hi)))))
      (define f (mk 100))
      (list (f) (f 5) (f 10 20))
      """

      assert run(source) == Value.list([100, 105, 130])
    end

    test "case-lambda nested inside case-lambda" do
      source = """
      (define f
        (case-lambda
          ((tag) (case-lambda
                   (() tag)
                   ((x) (cons tag x))))))
      (define inner (f 'outer))
      (list (inner) (inner 'inner-arg))
      """

      assert run(source) ==
               Value.list([
                 Value.symbol("outer"),
                 Value.pair(Value.symbol("outer"), Value.symbol("inner-arg"))
               ])
    end
  end

  describe "library surface" do
    test "case-lambda is unavailable in strict eval/2 without the import" do
      assert_raise Schooner.Eval.Error, fn ->
        Schooner.eval(
          "(define f (case-lambda ((x) x))) (f 1)",
          Env.new()
        )
      end
    end

    test "case-lambda becomes available after explicit import in strict eval/2" do
      source = """
      (import (scheme base) (scheme case-lambda))
      (define f (case-lambda ((x) (* x 3)) ((x y) (+ x y))))
      (list (f 4) (f 4 5))
      """

      assert Schooner.eval(source, Env.new()) == Value.list([12, 9])
    end
  end
end

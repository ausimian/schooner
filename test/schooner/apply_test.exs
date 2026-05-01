defmodule Schooner.ApplyTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Host
  alias Schooner.Value

  describe "apply!/2" do
    test "invokes a closure returned from eval!" do
      env = Environment.new()
      doubler = Schooner.eval!("(import (scheme base)) (lambda (x) (* x 2))", env)
      assert Schooner.apply!(doubler, [21]) == 42
    end

    test "invokes a primitive directly" do
      env = Environment.new()
      plus = Schooner.eval!("(import (scheme base)) +", env)
      assert Schooner.apply!(plus, [1, 2, 3]) == 6
    end

    test "invokes a parameter (zero-arg call returns current value)" do
      env = Environment.new()
      param = Schooner.eval!("(import (scheme base)) (make-parameter 42)", env)
      assert Schooner.apply!(param, []) == 42
    end

    test "non-procedure value raises Eval.Error" do
      assert_raise EvalError, fn -> Schooner.apply!(42, []) end
      assert_raise EvalError, fn -> Schooner.apply!("not-a-proc", [1, 2]) end
    end

    test "arity mismatch in closure raises Eval.Error" do
      env = Environment.new()
      f = Schooner.eval!("(import (scheme base)) (lambda (x y) (+ x y))", env)

      assert_raise EvalError, fn -> Schooner.apply!(f, [1]) end
      assert_raise EvalError, fn -> Schooner.apply!(f, [1, 2, 3]) end
    end

    test "callback pattern: host fn passes Scheme proc, then calls it" do
      called = self()

      lib =
        Host.library(
          primitives: [
            {"call-twice", 2,
             fn [proc, arg] ->
               first = Schooner.apply!(proc, [arg])
               second = Schooner.apply!(proc, [first])
               send(called, {:results, first, second})
               second
             end}
          ]
        )

      env = Environment.new(libraries: [lib])

      result =
        Schooner.eval!(
          "(import (scheme base)) (call-twice (lambda (x) (* x 2)) 5)",
          env
        )

      assert result == 20
      assert_received {:results, 10, 20}
    end
  end

  describe "apply/2 tagged-tuple wrapper" do
    test "returns {:ok, value} on success" do
      env = Environment.new()
      f = Schooner.eval!("(import (scheme base)) (lambda (x) x)", env)
      assert Schooner.apply(f, [Value.string("hi")]) == {:ok, "hi"}
    end

    test "returns {:error, _} for non-procedures" do
      assert {:error, %EvalError{}} = Schooner.apply(42, [])
    end

    test "returns {:error, _} for arity mismatches" do
      env = Environment.new()
      f = Schooner.eval!("(import (scheme base)) (lambda (x) x)", env)
      assert {:error, %EvalError{}} = Schooner.apply(f, [1, 2])
    end
  end
end

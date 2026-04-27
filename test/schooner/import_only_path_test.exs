defmodule Schooner.ImportOnlyPathTest do
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Eval.Error, as: EvalError

  describe "Schooner.run/1 implicit imports" do
    test "auto-imports standard libraries when none are explicit" do
      assert Schooner.run("(+ 1 2)") == 3
      assert Schooner.run("(sin 0)") == 0.0
      assert Schooner.run("(car '(1 2 3))") == 1
    end

    test "skips the implicit import when the script declares its own" do
      # An explicit import of (only (scheme base) +) means the script
      # opted in to a tighter surface. Without the implicit injection,
      # `sin` should be unbound.
      assert Schooner.run("(import (only (scheme base) +)) (+ 1 2)") == 3

      assert_raise EvalError, fn ->
        Schooner.run("(import (only (scheme base) +)) (sin 0)")
      end
    end
  end

  describe "Schooner.eval/2 strict path" do
    test "bindings come exclusively from imports + the supplied env" do
      assert Schooner.eval("(import (scheme base)) (+ 1 2)", Env.new()) == 3
    end

    test "without an import, even '+' is unbound on a fresh env" do
      assert_raise EvalError, fn ->
        Schooner.eval("(+ 1 2)", Env.new())
      end
    end

    test "explicit (only (scheme base) car) hides '+' from the script" do
      assert Schooner.eval(
               "(import (only (scheme base) car)) (car '(1 2 3))",
               Env.new()
             ) == 1

      assert_raise EvalError, fn ->
        Schooner.eval("(import (only (scheme base) car)) (+ 1 2)", Env.new())
      end
    end

    test "(scheme inexact) needs to be imported to use sin" do
      assert_raise EvalError, fn ->
        Schooner.eval("(import (scheme base)) (sin 0)", Env.new())
      end

      assert Schooner.eval(
               "(import (scheme base) (scheme inexact)) (sin 0)",
               Env.new()
             ) == 0.0
    end
  end
end

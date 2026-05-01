defmodule Schooner.ImportOnlyPathTest do
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Eval.Error, as: EvalError

  describe "Schooner.run/1 implicit imports" do
    test "auto-imports standard libraries when none are explicit" do
      assert Schooner.run!("(+ 1 2)") == 3
      assert Schooner.run!("(sin 0)") == 0.0
      assert Schooner.run!("(car '(1 2 3))") == 1
    end

    test "skips the implicit import when the script declares its own" do
      # An explicit import of (only (scheme base) +) means the script
      # opted in to a tighter surface. Without the implicit injection,
      # `sin` should be unbound.
      assert Schooner.run!("(import (only (scheme base) +)) (+ 1 2)") == 3

      assert_raise EvalError, fn ->
        Schooner.run!("(import (only (scheme base) +)) (sin 0)")
      end
    end
  end

  describe "Schooner.eval/2 strict path" do
    test "bindings come exclusively from imports + the supplied env" do
      assert Schooner.eval!("(import (scheme base)) (+ 1 2)", Env.new()) == 3
    end

    test "without an import, even '+' is unbound on a fresh env" do
      assert_raise EvalError, fn ->
        Schooner.eval!("(+ 1 2)", Env.new())
      end
    end

    test "the strict default does not pull in (scheme base)" do
      # Pin the sandbox guarantee that `eval/2` advertises in the
      # moduledoc: no auto-import of any shipped library, including
      # (scheme base). If this regresses, embedders relying on the
      # strict surface for untrusted input would silently lose it.
      # Names checked here are primitive procedure bindings — not
      # special forms or bootstrap-supplied macros, which dispatch on
      # the literal symbol regardless of imports.
      for binding <- ~w(+ - * / car cdr cons list display) do
        assert_raise EvalError, fn ->
          Schooner.eval!("(#{binding})", Env.new())
        end
      end
    end

    test "explicit (only (scheme base) car) hides '+' from the script" do
      assert Schooner.eval!(
               "(import (only (scheme base) car)) (car '(1 2 3))",
               Env.new()
             ) == 1

      assert_raise EvalError, fn ->
        Schooner.eval!("(import (only (scheme base) car)) (+ 1 2)", Env.new())
      end
    end

    test "(scheme inexact) needs to be imported to use sin" do
      assert_raise EvalError, fn ->
        Schooner.eval!("(import (scheme base)) (sin 0)", Env.new())
      end

      assert Schooner.eval!(
               "(import (scheme base) (scheme inexact)) (sin 0)",
               Env.new()
             ) == 0.0
    end
  end

  describe "Schooner.eval/3 :implicit_imports option" do
    test ":implicit_imports defaults to :none" do
      assert_raise EvalError, fn ->
        Schooner.eval!("(+ 1 2)", Env.new(), [])
      end
    end

    test ":implicit_imports: :none matches the eval/2 strict default" do
      assert_raise EvalError, fn ->
        Schooner.eval!("(+ 1 2)", Env.new(), implicit_imports: :none)
      end
    end

    test ":implicit_imports: :all auto-imports the standard libraries" do
      assert Schooner.eval!("(+ 1 2)", Env.new(), implicit_imports: :all) == 3
      assert Schooner.eval!("(sin 0)", Env.new(), implicit_imports: :all) == 0.0
    end

    test ":implicit_imports: :all is suppressed by an explicit import" do
      # Same opt-in semantics run/1 has: a single explicit import
      # disables the injection.
      assert Schooner.eval!(
               "(import (only (scheme base) +)) (+ 1 2)",
               Env.new(),
               implicit_imports: :all
             ) == 3

      assert_raise EvalError, fn ->
        Schooner.eval!(
          "(import (only (scheme base) +)) (sin 0)",
          Env.new(),
          implicit_imports: :all
        )
      end
    end

    test "run/1 is equivalent to eval/3 with implicit_imports: :all on a fresh env" do
      for source <- ["(+ 1 2)", "(sin 0)", "(import (only (scheme base) +)) (+ 1 2)"] do
        assert Schooner.run!(source) ==
                 Schooner.eval!(source, Env.new(), implicit_imports: :all)
      end
    end

    test "an unknown :implicit_imports value raises ArgumentError" do
      assert_raise ArgumentError, ~r/:implicit_imports/, fn ->
        Schooner.eval!("(+ 1 2)", Env.new(), implicit_imports: :everything)
      end
    end
  end
end

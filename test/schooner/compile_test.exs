defmodule Schooner.CompileTest do
  use ExUnit.Case, async: true

  alias Schooner.Compiled
  alias Schooner.Environment
  alias Schooner.Host
  alias Schooner.Reader.Error, as: ReaderError

  describe "compile!/1 default environment" do
    test "compiles + runs against the default standard registry" do
      compiled = Schooner.compile!("(import (scheme base)) (+ 1 2)")
      assert %Compiled{} = compiled
      assert is_list(compiled.program)
      assert is_map(compiled.var_bindings)
      assert Schooner.run_compiled!(compiled, Environment.new()) == 3
    end
  end

  describe "compile!/2 with explicit environment" do
    test "honours the registry for import resolution" do
      env = Environment.new(standard_libraries: [:base])
      compiled = Schooner.compile!("(import (scheme base)) (+ 1 2)", env)
      assert Schooner.run_compiled!(compiled, env) == 3
    end

    test "compile-time error surfaces (e.g. import of a missing library)" do
      env = Environment.new(standard_libraries: [:base])

      assert_raise Schooner.Library.NotFoundError, fn ->
        Schooner.compile!("(import (scheme inexact)) (sin 0)", env)
      end
    end

    test "captures imported macros — let etc. survive expansion" do
      env = Environment.new()
      compiled = Schooner.compile!("(import (scheme base)) (let ((x 5)) (* x 2))", env)
      assert Schooner.run_compiled!(compiled, env) == 10
    end
  end

  describe "compile then run multiple times" do
    test "compiled program is reusable; defines are applied to the runtime env on each run" do
      env = Environment.new()

      compiled =
        Schooner.compile!(
          "(import (scheme base)) (define x 7) (* x 6)",
          env
        )

      assert Schooner.run_compiled!(compiled, env) == 42
      assert Schooner.run_compiled!(compiled, env) == 42
    end

    test "two distinct envs produce independent runs (defines do not bleed)" do
      a = Environment.new()
      b = Environment.new()

      compiled =
        Schooner.compile!(
          "(import (scheme base)) (define counter 0) (define (next) counter) (next)",
          a
        )

      Schooner.run_compiled!(compiled, a)
      # define `counter` was applied to a's env, not b's. Run against b
      # should still complete successfully because the define re-runs
      # against b's globals.
      assert Schooner.run_compiled!(compiled, b) == 0
    end
  end

  describe "host primitives in compiled programs" do
    test "host library bindings resolved at compile time are baked in" do
      lib =
        Host.library(
          name: ["myapp"],
          primitives: [{"answer", 0, fn [] -> 42 end}]
        )

      env = Environment.new(libraries: [lib])

      compiled = Schooner.compile!("(import (myapp)) (answer)", env)
      assert Schooner.run_compiled!(compiled, env) == 42
    end

    test "anonymous host library bindings live on env, not in the artifact" do
      lib = Host.library(primitives: [{"answer", 0, fn [] -> 42 end}])
      env = Environment.new(libraries: [lib])

      compiled = Schooner.compile!("(answer)", env)
      assert Schooner.run_compiled!(compiled, env) == 42
    end
  end

  describe "compile/2 tagged-tuple wrapper" do
    test "returns {:ok, %Compiled{}} on success" do
      env = Environment.new()
      assert {:ok, %Compiled{}} = Schooner.compile("(import (scheme base)) 1", env)
    end

    test "returns {:error, _} on a parse error" do
      env = Environment.new()
      assert {:error, %ReaderError{}} = Schooner.compile("(", env)
    end

    test "compile/1 default-env wrapper works" do
      assert {:ok, %Compiled{}} = Schooner.compile("(import (scheme base)) 1")
    end
  end

  describe "run_compiled/2 tagged-tuple wrapper" do
    test "returns {:ok, value} on success" do
      env = Environment.new()
      compiled = Schooner.compile!("(import (scheme base)) (+ 1 2)", env)
      assert Schooner.run_compiled(compiled, env) == {:ok, 3}
    end

    test "returns {:error, _} for a runtime failure" do
      env = Environment.new()
      compiled = Schooner.compile!(~s|(import (scheme base)) (raise "oops")|, env)
      assert {:error, %Schooner.Error{}} = Schooner.run_compiled(compiled, env)
    end
  end
end

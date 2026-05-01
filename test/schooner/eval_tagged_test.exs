defmodule Schooner.EvalTaggedTest do
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Environment
  alias Schooner.Error, as: SchemeError
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Library.NotFoundError
  alias Schooner.Reader.Error, as: ReaderError

  describe "run/1 tagged-tuple wrapper" do
    test "returns {:ok, value} on success" do
      assert Schooner.run("(+ 1 2)") == {:ok, 3}
    end

    test "returns {:error, _} when the script errors at runtime" do
      assert {:error, %EvalError{}} =
               Schooner.run("(import (only (scheme base) +)) (sin 0)")
    end

    test "returns {:error, _} for a script that raises (uncaught Scheme error)" do
      assert {:error, %SchemeError{}} =
               Schooner.run("(raise \"oops\")")
    end

    test "returns {:error, _} on a parse-level failure" do
      assert {:error, %ReaderError{}} = Schooner.run("(")
    end
  end

  describe "eval/2 tagged-tuple wrapper" do
    test "with an Env returns {:ok, value}" do
      assert Schooner.eval("(import (scheme base)) (+ 1 2)", Env.new()) ==
               {:ok, 3}
    end

    test "with an Environment returns {:ok, value}" do
      env = Environment.new()
      assert Schooner.eval("(import (scheme base)) (+ 1 2)", env) == {:ok, 3}
    end

    test "returns {:error, _} for an unbound variable on a fresh strict env" do
      assert {:error, %EvalError{}} = Schooner.eval("(+ 1 2)", Env.new())
    end

    test "returns {:error, NotFoundError} for an import of a missing library" do
      assert {:error, %NotFoundError{}} =
               Schooner.eval("(import (no such lib)) 1", Env.new())
    end
  end

  describe "eval/3 tagged-tuple wrapper" do
    test "with implicit_imports: :all returns {:ok, value}" do
      assert Schooner.eval("(+ 1 2)", Env.new(), implicit_imports: :all) ==
               {:ok, 3}
    end

    test "ArgumentError on a bad option does NOT become {:error, _} — it is an embedder bug" do
      assert_raise ArgumentError, fn ->
        Schooner.eval("(+ 1 2)", Env.new(), implicit_imports: :everything)
      end
    end
  end

  describe "bang form raises (preserves prior contract)" do
    test "run! raises on script-level failure" do
      assert_raise SchemeError, fn -> Schooner.run!("(raise \"oops\")") end
    end

    test "eval! raises on script-level failure" do
      assert_raise EvalError, fn -> Schooner.eval!("(+ 1 2)", Env.new()) end
    end
  end
end

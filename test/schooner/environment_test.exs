defmodule Schooner.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Host
  alias Schooner.Library
  alias Schooner.Library.NotFoundError

  describe "new/1 — defaults" do
    test "no opts gives the default standard registry, no host libs, no pre-imports" do
      env = Environment.new()
      assert %Environment{} = env
      assert env.registry == Library.standard()
    end

    test "scripts evaluated against the default env still need imports for the strict surface" do
      env = Environment.new()

      assert_raise EvalError, fn -> Schooner.eval!("(+ 1 2)", env) end
      assert Schooner.eval!("(import (scheme base)) (+ 1 2)", env) == 3
    end
  end

  describe "new/1 — :standard_libraries" do
    test ":none gives an empty registry — no library is importable" do
      env = Environment.new(standard_libraries: :none)
      assert env.registry == %{}

      assert_raise NotFoundError, fn ->
        Schooner.eval!("(import (scheme base)) 1", env)
      end
    end

    test "atom shortcuts include exactly the named standard libraries" do
      env = Environment.new(standard_libraries: [:base, :char])
      assert Map.has_key?(env.registry, ["scheme", "base"])
      assert Map.has_key?(env.registry, ["scheme", "char"])
      refute Map.has_key?(env.registry, ["scheme", "inexact"])
    end

    test "canonical-name lists are accepted alongside atom shortcuts" do
      env = Environment.new(standard_libraries: [["scheme", "base"]])
      assert Map.has_key?(env.registry, ["scheme", "base"])
      assert map_size(env.registry) == 1
    end

    test "case_lambda and :case-lambda atom shortcuts both resolve" do
      env_underscored = Environment.new(standard_libraries: [:case_lambda])
      env_dashed = Environment.new(standard_libraries: [:"case-lambda"])

      assert Map.has_key?(env_underscored.registry, ["scheme", "case-lambda"])
      assert Map.has_key?(env_dashed.registry, ["scheme", "case-lambda"])
    end

    test "unknown atom shortcut raises ArgumentError" do
      assert_raise ArgumentError, ~r/shortcut :unknown is not recognised/, fn ->
        Environment.new(standard_libraries: [:unknown])
      end
    end

    test "non-shipped canonical name raises ArgumentError" do
      assert_raise ArgumentError, ~r/not shipped/, fn ->
        Environment.new(standard_libraries: [["scheme", "file"]])
      end
    end

    test "non-list non-:default non-:none value raises ArgumentError" do
      assert_raise ArgumentError, ~r/:standard_libraries must be/, fn ->
        Environment.new(standard_libraries: :everything)
      end
    end
  end

  describe "new/1 — host libraries (named)" do
    test "named host libraries register and the script can import them" do
      lib =
        Host.library(
          name: ["myapp", "log"],
          primitives: [
            {"info", 1, fn [_msg] -> :unspecified end}
          ]
        )

      env = Environment.new(libraries: [lib])
      assert Map.has_key?(env.registry, ["myapp", "log"])
      assert Schooner.eval!(~s|(import (myapp log)) (info "hi")|, env) == :unspecified
    end

    test "named host libraries do not enter scope without (import ...)" do
      lib =
        Host.library(
          name: ["myapp", "log"],
          primitives: [{"info", 1, fn [_msg] -> :unspecified end}]
        )

      env = Environment.new(libraries: [lib])

      assert_raise EvalError, fn ->
        Schooner.eval!(~s|(info "hi")|, env)
      end
    end
  end

  describe "new/1 — host libraries (anonymous)" do
    test "anonymous library bindings are auto-applied without an import" do
      lib =
        Host.library(primitives: [{"now-ms", 0, fn [] -> 12_345 end}])

      env = Environment.new(libraries: [lib])
      refute Map.has_key?(env.registry, [])
      assert Schooner.eval!("(now-ms)", env) == 12_345
    end

    test "anonymous + named libraries can coexist" do
      anon =
        Host.library(primitives: [{"now-ms", 0, fn [] -> 0 end}])

      named =
        Host.library(
          name: ["myapp", "log"],
          primitives: [{"info", 1, fn [_] -> :unspecified end}]
        )

      env = Environment.new(libraries: [anon, named])

      assert Schooner.eval!(
               "(import (myapp log)) (info (now-ms))",
               env
             ) == :unspecified
    end

    test "multiple anonymous libraries compose; later wins on collision" do
      first = Host.library(primitives: [{"f", 0, fn [] -> 1 end}])
      second = Host.library(primitives: [{"f", 0, fn [] -> 2 end}])

      env = Environment.new(libraries: [first, second])
      assert Schooner.eval!("(f)", env) == 2
    end
  end

  describe "new/1 — :pre_imports" do
    test "pre-imports a named library so the script does not need to" do
      lib =
        Host.library(
          name: ["myapp", "util"],
          primitives: [{"identity", 1, fn [v] -> v end}]
        )

      env =
        Environment.new(
          libraries: [lib],
          pre_imports: [["myapp", "util"]]
        )

      # No (import (myapp util)) in the source.
      assert Schooner.eval!("(identity 42)", env) == 42
    end

    test "raises if a pre-import refers to a missing library" do
      assert_raise NotFoundError, fn ->
        Environment.new(pre_imports: [["myapp", "missing"]])
      end
    end

    test "non-list pre_imports raises ArgumentError" do
      assert_raise ArgumentError, ~r/:pre_imports must be a list/, fn ->
        Environment.new(pre_imports: :all)
      end
    end

    test "non-canonical pre_imports entry raises ArgumentError" do
      assert_raise ArgumentError, ~r/canonical name list/, fn ->
        Environment.new(pre_imports: [:base])
      end
    end
  end

  describe "new/1 — :libraries validation" do
    test "non-list raises" do
      assert_raise ArgumentError, ~r/:libraries must be a list/, fn ->
        Environment.new(libraries: %{})
      end
    end

    test "non-Library entry raises" do
      assert_raise ArgumentError, ~r/must be a Schooner.Library/, fn ->
        Environment.new(libraries: [:not_a_lib])
      end
    end
  end

  describe "re-use across evaluations" do
    test "top-level defines persist across eval! calls" do
      env = Environment.new()
      Schooner.eval!("(import (scheme base)) (define x 100)", env)
      assert Schooner.eval!("(import (scheme base)) (* x 2)", env) == 200
    end
  end
end

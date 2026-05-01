defmodule Schooner.TimeTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Library
  alias Schooner.Library.NotFoundError

  describe "library/0" do
    test "builds a (scheme time) library exporting the three procedures" do
      lib = Schooner.Time.library()

      assert %Library{name: ["scheme", "time"]} = lib
      assert {:var, {:primitive, "current-second", 0, _}} = lib.exports["current-second"]
      assert {:var, {:primitive, "current-jiffy", 0, _}} = lib.exports["current-jiffy"]

      assert {:var, {:primitive, "jiffies-per-second", 0, _}} =
               lib.exports["jiffies-per-second"]

      assert map_size(lib.exports) == 3
    end

    test "is not in the standard registry — embedder must opt in" do
      refute Map.has_key?(Library.standard(), ["scheme", "time"])
    end

    test "(scheme time) is unreachable when the library is not registered" do
      env = Environment.new()

      assert_raise NotFoundError, fn ->
        Schooner.eval!("(import (scheme time)) (current-second)", env)
      end
    end
  end

  describe "current-second" do
    test "returns a positive inexact real" do
      env = env_with_time()
      result = Schooner.eval!("(import (scheme time)) (current-second)", env)

      assert is_float(result)
      assert result > 0.0
    end

    test "is roughly close to System.system_time(:second)" do
      env = env_with_time()
      before = System.system_time(:second)
      result = Schooner.eval!("(import (scheme time)) (current-second)", env)
      later = System.system_time(:second)

      # 1-second slack on each side absorbs any scheduling noise between
      # the host clock read and the script's clock read.
      assert result >= before - 1.0
      assert result <= later + 1.0
    end
  end

  describe "current-jiffy" do
    test "returns an exact integer" do
      env = env_with_time()
      result = Schooner.eval!("(import (scheme time)) (current-jiffy)", env)

      assert is_integer(result)
    end

    test "is monotonic — a later call returns a value >= the earlier one" do
      env = env_with_time()

      source = """
      (import (scheme base) (scheme time))
      (define a (current-jiffy))
      (define b (current-jiffy))
      (>= b a)
      """

      assert Schooner.eval!(source, env) === true
    end
  end

  describe "jiffies-per-second" do
    test "returns a positive exact integer" do
      env = env_with_time()
      result = Schooner.eval!("(import (scheme time)) (jiffies-per-second)", env)

      assert is_integer(result)
      assert result > 0
    end

    test "matches :erlang.convert_time_unit/3" do
      env = env_with_time()
      expected = :erlang.convert_time_unit(1, :second, :native)
      assert Schooner.eval!("(import (scheme time)) (jiffies-per-second)", env) == expected
    end
  end

  describe "embedding shape — composes with other libraries" do
    test "named alongside other host libraries; both reachable via explicit import" do
      other =
        Schooner.Host.library(
          name: ["myapp", "util"],
          primitives: [{"identity", 1, fn [v] -> v end}]
        )

      env = Environment.new(libraries: [Schooner.Time.library(), other])

      source = """
      (import (scheme time) (myapp util))
      (identity (jiffies-per-second))
      """

      result = Schooner.eval!(source, env)
      assert is_integer(result)
      assert result > 0
    end

    test "absence is sandbox-safe even with default standard libraries listed" do
      env = Environment.new()

      assert_raise EvalError, fn ->
        Schooner.eval!("(current-second)", env)
      end
    end
  end

  defp env_with_time do
    Environment.new(libraries: [Schooner.Time.library()])
  end
end

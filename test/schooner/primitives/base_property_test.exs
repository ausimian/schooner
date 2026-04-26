defmodule Schooner.Primitives.BasePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  defp run(source), do: Schooner.run(source)

  defp small_int, do: integer(-100..100)

  property "+ is associative on small integers" do
    check all(
            a <- small_int(),
            b <- small_int(),
            c <- small_int()
          ) do
      lhs = run("(+ (+ #{a} #{b}) #{c})")
      rhs = run("(+ #{a} (+ #{b} #{c}))")
      assert lhs === rhs
    end
  end

  property "+ is commutative on small integers" do
    check all(a <- small_int(), b <- small_int()) do
      assert run("(+ #{a} #{b})") === run("(+ #{b} #{a})")
    end
  end

  property "0 is the additive identity" do
    check all(a <- small_int()) do
      assert run("(+ #{a} 0)") === a
      assert run("(+ 0 #{a})") === a
    end
  end

  property "* is associative on small integers" do
    check all(
            a <- small_int(),
            b <- small_int(),
            c <- small_int()
          ) do
      lhs = run("(* (* #{a} #{b}) #{c})")
      rhs = run("(* #{a} (* #{b} #{c}))")
      assert lhs === rhs
    end
  end

  property "* is commutative on small integers" do
    check all(a <- small_int(), b <- small_int()) do
      assert run("(* #{a} #{b})") === run("(* #{b} #{a})")
    end
  end

  property "1 is the multiplicative identity" do
    check all(a <- small_int()) do
      assert run("(* #{a} 1)") === a
      assert run("(* 1 #{a})") === a
    end
  end

  property "(- a b) = (+ a (- b))" do
    check all(a <- small_int(), b <- small_int()) do
      assert run("(- #{a} #{b})") === run("(+ #{a} (- #{b}))")
    end
  end
end

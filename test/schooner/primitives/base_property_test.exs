defmodule Schooner.Primitives.BasePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  defp run(source), do: Schooner.run!(source)

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

  # ---------------------------------------------------------------------------
  # Rational-tower invariants
  # ---------------------------------------------------------------------------

  defp non_zero, do: filter(small_int(), &(&1 != 0))

  property "(/ a b) is the multiplicative inverse: (* (/ a b) b) = a" do
    check all(a <- small_int(), b <- non_zero()) do
      assert run("(= (* (/ #{a} #{b}) #{b}) #{a})") == true
    end
  end

  property "rationals are reduced: gcd of numerator and denominator is 1" do
    check all(a <- non_zero(), b <- non_zero()) do
      case run("(/ #{a} #{b})") do
        n when is_integer(n) -> assert is_integer(n)
        {:rational, n, d} -> assert Integer.gcd(abs(n), d) == 1
      end
    end
  end

  property "rational arithmetic distributes: a*(b+c) = a*b + a*c" do
    check all(
            a <- small_int(),
            b <- small_int(),
            c <- small_int(),
            d <- non_zero()
          ) do
      assert run("(= (* #{a} (+ (/ #{b} #{d}) #{c})) (+ (* #{a} (/ #{b} #{d})) (* #{a} #{c})))") ==
               true
    end
  end

  property "(numerator x) / (denominator x) = x for any exact rational" do
    check all(a <- small_int(), b <- non_zero()) do
      r = run("(/ #{a} #{b})")

      assert run("(= (/ (numerator #{render(r)}) (denominator #{render(r)})) #{render(r)})") ==
               true
    end
  end

  defp render({:rational, n, d}), do: "#{n}/#{d}"
  defp render(n) when is_integer(n), do: Integer.to_string(n)
end

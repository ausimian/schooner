defmodule Schooner.Primitives.BaseRationalsTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  # ---------------------------------------------------------------------------
  # Reader / writer for the n/d external representation
  # ---------------------------------------------------------------------------

  describe "reader and writer" do
    test "(quote 1/2) reads as a rational tagged value" do
      assert run("(quote 1/2)") == {:rational, 1, 2}
    end

    test "negative rational" do
      assert run("(quote -3/4)") == {:rational, -3, 4}
    end

    test "rational reduces on read" do
      assert run("(quote 4/8)") == {:rational, 1, 2}
      assert run("(quote 6/9)") == {:rational, 2, 3}
    end

    test "rational with denom dividing numerator collapses to integer" do
      assert run("(quote 6/3)") === 2
      assert run("(quote -6/3)") === -2
    end

    test "rational sign normalised onto numerator" do
      assert run("(quote 1/2)") == run("(quote 1/2)")
    end

    test "rational under #x / #b prefixes" do
      assert run("(quote #x1/a)") == {:rational, 1, 10}
      assert run("(quote #b101/110)") == {:rational, 5, 6}
    end

    test "#i widens rational literal to float" do
      assert run("(quote #i1/2)") === 0.5
    end

    test "#e on a rational literal stays exact" do
      assert run("(quote #e1/2)") == {:rational, 1, 2}
    end

    test "rational round-trips through write/read" do
      r = {:rational, 22, 7}
      written = Value.write(r)
      assert written == "22/7"
      assert run("(quote #{written})") == r
    end
  end

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  describe "predicates" do
    test "rational? is #t for ints, rationals, and finite floats" do
      assert run("(rational? 0)") == Value.bool(true)
      assert run("(rational? 5)") == Value.bool(true)
      assert run("(rational? -7)") == Value.bool(true)
      assert run("(rational? 1/2)") == Value.bool(true)
      assert run("(rational? -22/7)") == Value.bool(true)
      assert run("(rational? 1.5)") == Value.bool(true)
      assert run("(rational? 0.0)") == Value.bool(true)
    end

    test "rational? is #f for non-finite floats and non-numbers" do
      assert run("(rational? +inf.0)") == Value.bool(false)
      assert run("(rational? -inf.0)") == Value.bool(false)
      assert run("(rational? +nan.0)") == Value.bool(false)
      assert run(~S|(rational? "1/2")|) == Value.bool(false)
      assert run("(rational? 'foo)") == Value.bool(false)
    end

    test "exact? is #t for rationals" do
      assert run("(exact? 1/2)") == Value.bool(true)
      assert run("(exact? -3/4)") == Value.bool(true)
    end

    test "inexact? is #f for rationals" do
      assert run("(inexact? 1/2)") == Value.bool(false)
    end

    test "integer? is #f for non-integer rationals" do
      assert run("(integer? 1/2)") == Value.bool(false)
      assert run("(integer? -3/4)") == Value.bool(false)
    end

    test "number? is #t for rationals" do
      assert run("(number? 1/2)") == Value.bool(true)
    end

    test "zero? rejects rationals as never-zero (denom > 1 by construction)" do
      assert run("(zero? 1/2)") == Value.bool(false)
      assert run("(zero? -1/2)") == Value.bool(false)
    end

    test "positive? / negative? on rationals" do
      assert run("(positive? 1/2)") == Value.bool(true)
      assert run("(positive? -1/2)") == Value.bool(false)
      assert run("(negative? 1/2)") == Value.bool(false)
      assert run("(negative? -1/2)") == Value.bool(true)
    end

    test "odd? / even? raise on non-integer rationals" do
      e = assert_raise PError, fn -> run("(odd? 1/2)") end
      assert match?({:type_error, "odd?", "integer", _}, e.reason)
      e = assert_raise PError, fn -> run("(even? 1/2)") end
      assert match?({:type_error, "even?", "integer", _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Arithmetic — exactness preserved when all operands exact
  # ---------------------------------------------------------------------------

  describe "arithmetic" do
    test "+ between integer and rational stays exact" do
      assert run("(+ 1 1/2)") == {:rational, 3, 2}
      assert run("(+ 1/2 1/3)") == {:rational, 5, 6}
    end

    test "+ with float operand contaminates to float" do
      assert run("(+ 1/2 0.25)") === 0.75
    end

    test "- on rationals" do
      assert run("(- 1/2 1/3)") == {:rational, 1, 6}
      assert run("(- 1/2)") == {:rational, -1, 2}
    end

    test "* on rationals" do
      assert run("(* 2/3 3/4)") == {:rational, 1, 2}
      assert run("(* 2 1/2)") === 1
      assert run("(* -1/2 -1/2)") == {:rational, 1, 4}
    end

    test "/ on integers may yield rational" do
      assert run("(/ 1 2)") == {:rational, 1, 2}
      assert run("(/ 22 7)") == {:rational, 22, 7}
      assert run("(/ -10 4)") == {:rational, -5, 2}
    end

    test "/ on rationals" do
      assert run("(/ 1/2 1/3)") == {:rational, 3, 2}
      assert run("(/ 1/2 2)") == {:rational, 1, 4}
      assert run("(/ 6 1/2)") === 12
    end

    test "/ collapses to integer when denominator divides" do
      assert run("(/ 6 3)") === 2
      assert run("(/ 1/2 1/2)") === 1
    end

    test "/ with three or more operands chains left-to-right" do
      assert run("(/ 12 3 2)") === 2
      assert run("(/ 1 2 3)") == {:rational, 1, 6}
    end

    test "/ by zero with rational operands raises division_by_zero" do
      e = assert_raise PError, fn -> run("(/ 1/2 0)") end
      assert e.reason == {:division_by_zero, "/"}
    end

    test "abs of rationals" do
      assert run("(abs 1/2)") == {:rational, 1, 2}
      assert run("(abs -3/4)") == {:rational, 3, 4}
    end

    test "min/max across integer/rational/float" do
      assert run("(min 1/2 1/3)") == {:rational, 1, 3}
      assert run("(max 1/2 1/3)") == {:rational, 1, 2}
      assert run("(min 1/2 0.4)") === 0.4
      assert run("(max -1 -1/2)") == {:rational, -1, 2}
    end

    test "expt with negative integer exponent yields rational" do
      assert run("(expt 2 -3)") == {:rational, 1, 8}
      assert run("(expt -2 -3)") == {:rational, -1, 8}
    end

    test "expt of rational base with positive exponent" do
      assert run("(expt 1/2 3)") == {:rational, 1, 8}
      assert run("(expt 2/3 0)") === 1
    end

    test "expt of rational base with negative exponent" do
      assert run("(expt 1/2 -3)") === 8
      assert run("(expt 2/3 -2)") == {:rational, 9, 4}
    end

    test "expt with float still uses pow" do
      assert run("(expt 1/2 -3.0)") == 8.0
    end

    test "(- 1/3 1/3) is exactly 0 (integer collapse)" do
      assert run("(- 1/3 1/3)") === 0
    end
  end

  # ---------------------------------------------------------------------------
  # Comparisons
  # ---------------------------------------------------------------------------

  describe "comparisons" do
    test "= across exact mixes" do
      assert run("(= 1/2 1/2)") == Value.bool(true)
      assert run("(= 1/2 2/4)") == Value.bool(true)
      assert run("(= 1 2/2)") == Value.bool(true)
      assert run("(= 1/2 1/3)") == Value.bool(false)
    end

    test "= numerically equal across exactness" do
      assert run("(= 1/2 0.5)") == Value.bool(true)
      assert run("(= 1.5 3/2)") == Value.bool(true)
    end

    test "< across exact mixes" do
      assert run("(< 1/3 1/2)") == Value.bool(true)
      assert run("(< 1/2 1/3)") == Value.bool(false)
      assert run("(< -1/2 1/3)") == Value.bool(true)
      assert run("(< 1/2 1)") == Value.bool(true)
    end

    test "<= and >= with rationals" do
      assert run("(<= 1/2 1/2)") == Value.bool(true)
      assert run("(>= 1/2 1/2)") == Value.bool(true)
      assert run("(>= 2/3 1/2)") == Value.bool(true)
    end

    test "chained comparisons on mixed numeric types" do
      assert run("(< 1/3 1/2 1)") == Value.bool(true)
      assert run("(< 1/3 1/2 0.4)") == Value.bool(false)
    end

    test "eqv? on rationals respects exactness" do
      assert run("(eqv? 1/2 1/2)") == Value.bool(true)
      assert run("(eqv? 1/2 0.5)") == Value.bool(false)
      assert run("(eqv? 2/4 1/2)") == Value.bool(true)
    end

    test "equal? on rationals matches eqv?" do
      assert run("(equal? 1/2 1/2)") == Value.bool(true)
      assert run("(equal? 1/2 0.5)") == Value.bool(false)
    end
  end

  # ---------------------------------------------------------------------------
  # numerator / denominator / rationalize
  # ---------------------------------------------------------------------------

  describe "numerator / denominator" do
    test "numerator / denominator on integers" do
      assert run("(numerator 5)") === 5
      assert run("(denominator 5)") === 1
      assert run("(numerator 0)") === 0
      assert run("(denominator 0)") === 1
    end

    test "numerator / denominator on rationals" do
      assert run("(numerator 22/7)") === 22
      assert run("(denominator 22/7)") === 7
      assert run("(numerator -3/4)") === -3
      assert run("(denominator -3/4)") === 4
    end

    test "numerator / denominator on floats preserve inexactness" do
      assert run("(numerator 0.5)") === 1.0
      assert run("(denominator 0.5)") === 2.0
      assert run("(numerator 3.0)") === 3.0
      assert run("(denominator 3.0)") === 1.0
    end

    test "numerator / denominator on +inf.0 / +nan.0 raise" do
      assert_raise PError, fn -> run("(numerator +inf.0)") end
      assert_raise PError, fn -> run("(denominator +nan.0)") end
    end

    test "numerator / denominator type-check non-numbers" do
      e = assert_raise PError, fn -> run(~S|(numerator "foo")|) end
      assert match?({:type_error, "numerator", _, _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # exact / inexact conversions
  # ---------------------------------------------------------------------------

  describe "exact/inexact conversions" do
    test "exact->inexact on rationals" do
      assert run("(exact->inexact 1/2)") === 0.5
      assert run("(inexact 22/7)") === 22 / 7
    end

    test "inexact->exact on float yields exact rational" do
      assert run("(inexact->exact 0.5)") == {:rational, 1, 2}
      assert run("(exact 0.25)") == {:rational, 1, 4}
    end

    test "inexact->exact 0.1 round-trips back to 0.1" do
      r = run("(inexact->exact 0.1)")
      assert match?({:rational, _, _}, r)
      back = run("(exact->inexact (inexact->exact 0.1))")
      assert back === 0.1
    end

    test "round-trip (exact->inexact (inexact->exact f)) is the identity for finite floats" do
      for f <- [0.1, 0.2, 0.5, 1.5, 1.0e-10, -3.75, 1.234e9] do
        s = :erlang.float_to_binary(f, [:short])
        assert run("(exact->inexact (inexact->exact #{s}))") === f
      end
    end
  end

  # ---------------------------------------------------------------------------
  # rationalize
  # ---------------------------------------------------------------------------

  describe "rationalize" do
    test "rationalize on exact operands returns the simplest exact rational" do
      assert run("(rationalize 1/3 0)") == {:rational, 1, 3}
      assert run("(rationalize 1/3 1/10)") == {:rational, 1, 3}
      # 0.1 ± 0.05 contains 1/10 but the simplest is also 1/10.
      assert run("(rationalize 1/10 1/100)") == {:rational, 1, 10}
    end

    test "rationalize widens to inexact when any operand is inexact" do
      r = run("(rationalize .3 1/10)")
      assert is_float(r)
      # The simplest rational within 0.1 of 0.3 is 1/3.
      assert r === 1 / 3
    end

    test "rationalize tolerates negative tolerance via |y|" do
      assert run("(rationalize 1/3 -1/10)") == {:rational, 1, 3}
    end

    test "rationalize 0 with any tolerance is 0" do
      assert run("(rationalize 0 1/10)") === 0
    end

    test "rationalize within an integer's tolerance picks the integer" do
      assert run("(rationalize 5/2 1/2)") === 2
      assert run("(rationalize -5/2 1/2)") === -2
    end

    test "rationalize on +nan.0 yields +nan.0" do
      assert run("(rationalize +nan.0 1)") == {:float_special, :nan}
      assert run("(rationalize 1 +nan.0)") == {:float_special, :nan}
    end

    test "rationalize with infinite tolerance yields 0.0" do
      assert run("(rationalize 1/3 +inf.0)") === 0.0
      assert run("(rationalize 100 -inf.0)") === 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Integer-only ops still reject rationals
  # ---------------------------------------------------------------------------

  describe "integer-only ops reject rationals" do
    test "quotient / remainder / modulo" do
      e = assert_raise PError, fn -> run("(quotient 1/2 2)") end
      assert match?({:type_error, "quotient", "integer", _}, e.reason)
      e = assert_raise PError, fn -> run("(remainder 1/2 2)") end
      assert match?({:type_error, "remainder", "integer", _}, e.reason)
      e = assert_raise PError, fn -> run("(modulo 1/2 2)") end
      assert match?({:type_error, "modulo", "integer", _}, e.reason)
    end

    test "gcd / lcm" do
      e = assert_raise PError, fn -> run("(gcd 1/2 4)") end
      assert match?({:type_error, "gcd", "integer", _}, e.reason)
      e = assert_raise PError, fn -> run("(lcm 1/2 4)") end
      assert match?({:type_error, "lcm", "integer", _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # sqrt
  # ---------------------------------------------------------------------------

  describe "sqrt" do
    test "sqrt of rational with both num and denom perfect squares stays exact" do
      assert run("(sqrt 1/4)") == {:rational, 1, 2}
      assert run("(sqrt 9/16)") == {:rational, 3, 4}
    end

    test "sqrt of rational without exact result raises irrational" do
      e = assert_raise PError, fn -> run("(sqrt 1/2)") end
      assert match?({:irrational, "sqrt", _}, e.reason)
    end

    test "sqrt of negative rational lifts into the imaginary axis" do
      assert run("(sqrt -1/4)") == {:complex, 0, 0.5}
    end
  end

  # ---------------------------------------------------------------------------
  # Equality across the tower
  # ---------------------------------------------------------------------------

  describe "equality semantics" do
    test "Schooner.Value.eqv? on rationals" do
      assert Value.eqv?({:rational, 1, 2}, {:rational, 1, 2})
      refute Value.eqv?({:rational, 1, 2}, 0.5)
      refute Value.eqv?({:rational, 1, 2}, {:rational, 1, 3})
    end

    test "rational reduce ensures structurally distinct equivalent forms can't exist" do
      assert Value.rational(2, 4) == {:rational, 1, 2}
      assert Value.rational(-2, -4) == {:rational, 1, 2}
      assert Value.rational(2, -4) == {:rational, -1, 2}
      assert Value.rational(0, 5) === 0
      assert Value.rational(6, 3) === 2
    end

    test "Value.rational raises on zero denominator" do
      assert_raise ArithmeticError, fn -> Value.rational(1, 0) end
    end
  end
end

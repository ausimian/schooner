defmodule Schooner.Primitives.BaseTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  # ---------------------------------------------------------------------------
  # Arithmetic — exactness contamination matrix
  # ---------------------------------------------------------------------------

  describe "exactness contamination" do
    test "+ — exact/exact stays exact, any inexact contaminates" do
      assert run("(+ 1 2)") === 3
      assert run("(+ 1 2.0)") === 3.0
      assert run("(+ 1.0 2.0)") === 3.0
    end

    test "- contamination" do
      assert run("(- 5 2)") === 3
      assert run("(- 5 2.0)") === 3.0
      assert run("(- 5.0 2.0)") === 3.0
    end

    test "* contamination" do
      assert run("(* 4 5)") === 20
      assert run("(* 4 5.0)") === 20.0
      assert run("(* 4.0 5.0)") === 20.0
    end

    test "/ contamination" do
      assert run("(/ 6 3)") === 2
      assert run("(/ 6 3.0)") === 2.0
      assert run("(/ 6.0 3.0)") === 2.0
    end

    test "quotient/remainder/modulo contamination" do
      assert run("(quotient 7 3)") === 2
      assert run("(quotient 7.0 3)") === 2.0
      assert run("(remainder 7 3)") === 1
      assert run("(remainder 7 3.0)") === 1.0
      assert run("(modulo 7 3)") === 1
      assert run("(modulo 7 3.0)") === 1.0
    end

    test "min/max contamination" do
      assert run("(min 3 1 2)") === 1
      assert run("(min 3 1.0 2)") === 1.0
      assert run("(max 1 2 3)") === 3
      assert run("(max 1 2.0 3)") === 3.0
    end

    test "expt contamination" do
      assert run("(expt 2 10)") === 1024
      assert run("(expt 2.0 10)") === 1024.0
      assert run("(expt 2 10.0)") === 1024.0
    end

    test "abs contamination preserves operand exactness" do
      assert run("(abs -5)") === 5
      assert run("(abs -5.0)") === 5.0
    end

    test "gcd/lcm contamination" do
      assert run("(gcd 12 18)") === 6
      assert run("(gcd 12 18.0)") === 6.0
      assert run("(lcm 4 6)") === 12
      assert run("(lcm 4 6.0)") === 12.0
    end
  end

  # ---------------------------------------------------------------------------
  # Arbitrary-precision integers
  # ---------------------------------------------------------------------------

  describe "arbitrary-precision integers" do
    test "(* 10000000000 10000000000) is exact and does not overflow" do
      n = run("(* 10000000000 10000000000)")
      assert is_integer(n)
      assert n === 100_000_000_000_000_000_000
    end

    test "expt produces big integers exactly" do
      assert run("(expt 2 100)") === 1_267_650_600_228_229_401_496_703_205_376
    end

    test "factorial via expt and *" do
      assert run("(* (expt 2 64) 1)") === 18_446_744_073_709_551_616
    end
  end

  # ---------------------------------------------------------------------------
  # Float edge cases — rendering
  # ---------------------------------------------------------------------------

  describe "float edge cases" do
    test "negative zero renders" do
      assert Value.write(run("(* -1.0 0.0)")) =~ "0"
    end

    test "(/ 1.0 0.0) yields +inf.0 (IEEE-754, closes #8)" do
      assert run("(/ 1.0 0.0)") == {:float_special, :pos_inf}
    end

    test "rendered floats round-trip via re-evaluation" do
      v = run("3.1415")
      assert Value.write(v) == "3.1415"
      assert run(Value.write(v)) === v
    end

    test "small float renders without surprising scientific notation" do
      assert Value.write(run("0.5")) == "0.5"
    end

    test "+inf.0 / -inf.0 / +nan.0 round-trip through write/read" do
      assert Value.write(run("+inf.0")) == "+inf.0"
      assert Value.write(run("-inf.0")) == "-inf.0"
      assert Value.write(run("+nan.0")) == "+nan.0"
    end
  end

  # ---------------------------------------------------------------------------
  # Comparison
  # ---------------------------------------------------------------------------

  describe "comparison" do
    test "= variadic" do
      assert run("(= 1 1)") == Value.bool(true)
      assert run("(= 1 1 1 1)") == Value.bool(true)
      assert run("(= 1 1.0)") == Value.bool(true)
      assert run("(= 1 2)") == Value.bool(false)
      assert run("(= 1)") == Value.bool(true)
    end

    test "< variadic strict" do
      assert run("(< 1 2 3)") == Value.bool(true)
      assert run("(< 1 1 2)") == Value.bool(false)
      assert run("(< 3 2 1)") == Value.bool(false)
    end

    test "> < <= >= variadic" do
      assert run("(> 3 2 1)") == Value.bool(true)
      assert run("(<= 1 1 2)") == Value.bool(true)
      assert run("(>= 3 3 1)") == Value.bool(true)
    end
  end

  # ---------------------------------------------------------------------------
  # Predicates — table-driven
  # ---------------------------------------------------------------------------

  describe "predicates over a fixture covering each value tag" do
    @predicates [
      "number?",
      "integer?",
      "exact?",
      "inexact?",
      "boolean?",
      "pair?",
      "null?",
      "symbol?",
      "string?",
      "char?",
      "vector?",
      "bytevector?",
      "procedure?",
      "eof-object?"
    ]

    @fixture [
      {"42", [:number, :integer, :exact]},
      {"-7", [:number, :integer, :exact]},
      {"3.14", [:number, :inexact]},
      {"2.0", [:number, :integer, :inexact]},
      {"#t", [:boolean]},
      {"#f", [:boolean]},
      {"'()", [:null]},
      {"'(1 2)", [:pair]},
      {"'foo", [:symbol]},
      {~S("hi"), [:string]},
      {~S(#\a), [:char]},
      {"#(1 2 3)", [:vector]},
      {"#u8(1 2 3)", [:bytevector]},
      {"(lambda (x) x)", [:procedure]},
      {"+", [:procedure]}
    ]

    @pred_to_tag %{
      "number?" => :number,
      "integer?" => :integer,
      "exact?" => :exact,
      "inexact?" => :inexact,
      "boolean?" => :boolean,
      "pair?" => :pair,
      "null?" => :null,
      "symbol?" => :symbol,
      "string?" => :string,
      "char?" => :char,
      "vector?" => :vector,
      "bytevector?" => :bytevector,
      "procedure?" => :procedure,
      "eof-object?" => :eof
    }

    test "every predicate returns expected value over every fixture entry" do
      for {literal, tags} <- @fixture, pred <- @predicates do
        tag = Map.fetch!(@pred_to_tag, pred)
        expected = Value.bool(tag in tags)
        actual = Schooner.run("(#{pred} #{literal})")

        assert actual == expected,
               "(#{pred} #{literal}) => #{inspect(actual)} (want #{inspect(expected)})"
      end
    end

    test "zero?/positive?/negative?" do
      assert run("(zero? 0)") == Value.bool(true)
      assert run("(zero? 0.0)") == Value.bool(true)
      assert run("(zero? 1)") == Value.bool(false)
      assert run("(positive? 1)") == Value.bool(true)
      assert run("(positive? -1)") == Value.bool(false)
      assert run("(positive? 0)") == Value.bool(false)
      assert run("(negative? -1)") == Value.bool(true)
      assert run("(negative? 0)") == Value.bool(false)
    end

    test "odd?/even?" do
      assert run("(odd? 3)") == Value.bool(true)
      assert run("(odd? 4)") == Value.bool(false)
      assert run("(even? 4)") == Value.bool(true)
      assert run("(even? 5)") == Value.bool(false)
      assert run("(even? 4.0)") == Value.bool(true)
    end

    test "boolean=? requires at least two booleans" do
      assert run("(boolean=? #t #t)") == Value.bool(true)
      assert run("(boolean=? #t #f)") == Value.bool(false)
      assert run("(boolean=? #t #t #t)") == Value.bool(true)
      assert run("(boolean=? #t #t #f)") == Value.bool(false)
    end

    test "not" do
      assert run("(not #f)") == Value.bool(true)
      assert run("(not #t)") == Value.bool(false)
      assert run("(not 0)") == Value.bool(false)
      assert run("(not '())") == Value.bool(false)
    end
  end

  # ---------------------------------------------------------------------------
  # Documented "would require rationals/complex" errors
  # ---------------------------------------------------------------------------

  describe "raises on rationals/complex" do
    test "(/ 1 3) with exact operands raises exact_division_not_integer" do
      e = assert_raise PError, fn -> run("(/ 1 3)") end
      assert match?({:exact_division_not_integer, 1, 3}, e.reason)
    end

    test "(/ 6 3) with exact operands stays exact" do
      assert run("(/ 6 3)") === 2
    end

    test "(/ 1.0 3) is fine because float operand contaminates" do
      assert is_float(run("(/ 1.0 3)"))
    end

    test "(sqrt 2) with non-square exact integer raises irrational" do
      e = assert_raise PError, fn -> run("(sqrt 2)") end
      assert match?({:irrational, "sqrt", 2}, e.reason)
    end

    test "(sqrt 4) returns exact 2" do
      assert run("(sqrt 4)") === 2
    end

    test "(sqrt 2.0) returns float (inexact context)" do
      assert run("(sqrt 2.0)") == :math.sqrt(2.0)
    end

    test "(sqrt -1) raises irrational" do
      e = assert_raise PError, fn -> run("(sqrt -1)") end
      assert match?({:irrational, "sqrt", -1}, e.reason)
    end

    test "(expt 2 -3) on integers raises negative_exponent" do
      e = assert_raise PError, fn -> run("(expt 2 -3)") end
      assert match?({:negative_exponent, 2, -3}, e.reason)
    end

    test "(expt 1 -3) returns 1 (no rational needed)" do
      assert run("(expt 1 -3)") === 1
    end

    test "(expt -1 -3) returns -1" do
      assert run("(expt -1 -3)") === -1
    end

    test "(expt 2.0 -3) returns float" do
      assert run("(expt 2.0 -3)") == 0.125
    end
  end

  # ---------------------------------------------------------------------------
  # Type errors and division by zero
  # ---------------------------------------------------------------------------

  describe "type errors" do
    test "(+ 1 \"two\") raises type_error" do
      e = assert_raise PError, fn -> run(~S|(+ 1 "two")|) end
      assert match?({:type_error, "+", "number", _}, e.reason)
    end

    test "(quotient 5 0) raises division_by_zero" do
      e = assert_raise PError, fn -> run("(quotient 5 0)") end
      assert e.reason == {:division_by_zero, "quotient"}
    end

    test "(/ 1 0) raises division_by_zero" do
      e = assert_raise PError, fn -> run("(/ 1 0)") end
      assert e.reason == {:division_by_zero, "/"}
    end

    test "(modulo 5 0) raises division_by_zero" do
      e = assert_raise PError, fn -> run("(modulo 5 0)") end
      assert e.reason == {:division_by_zero, "modulo"}
    end

    test "(boolean=? #t 1) raises type_error" do
      e = assert_raise PError, fn -> run("(boolean=? #t 1)") end
      assert match?({:type_error, "boolean=?", "boolean", _}, e.reason)
    end

    test "(odd? 1.5) raises type_error (not an integer)" do
      e = assert_raise PError, fn -> run("(odd? 1.5)") end
      assert match?({:type_error, "odd?", "integer", _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # exact/inexact conversions
  # ---------------------------------------------------------------------------

  describe "exact/inexact conversions" do
    test "exact->inexact on integers" do
      assert run("(exact->inexact 3)") === 3.0
    end

    test "exact->inexact on floats is identity" do
      assert run("(exact->inexact 3.0)") === 3.0
    end

    test "inexact->exact on integer-valued floats" do
      assert run("(inexact->exact 3.0)") === 3
    end

    test "inexact->exact on non-integer float raises" do
      e = assert_raise PError, fn -> run("(inexact->exact 1.5)") end
      assert match?({:not_representable_exact, _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Variadic edge cases
  # ---------------------------------------------------------------------------

  describe "variadic edge cases" do
    test "(+) is 0; (*) is 1" do
      assert run("(+)") === 0
      assert run("(*)") === 1
    end

    test "(- n) negates" do
      assert run("(- 5)") === -5
      assert run("(- 5.0)") === -5.0
    end

    test "(/ n) reciprocates only when exact-divisible" do
      assert run("(/ 1.0)") === 1.0
      assert_raise PError, fn -> run("(/ 3)") end
    end

    test "(gcd) is 0; (lcm) is 1" do
      assert run("(gcd)") === 0
      assert run("(lcm)") === 1
    end
  end

  # ---------------------------------------------------------------------------
  # Non-finite floats — arithmetic propagation
  # ---------------------------------------------------------------------------

  describe "non-finite arithmetic propagation" do
    @pos_inf {:float_special, :pos_inf}
    @neg_inf {:float_special, :neg_inf}
    @nan {:float_special, :nan}

    test "NaN propagates through +, -, *, /" do
      assert run("(+ +nan.0 1)") == @nan
      assert run("(+ 1 +nan.0)") == @nan
      assert run("(- +nan.0 1)") == @nan
      assert run("(- 1 +nan.0)") == @nan
      assert run("(* +nan.0 2.0)") == @nan
      assert run("(/ +nan.0 2)") == @nan
      assert run("(/ 2 +nan.0)") == @nan
    end

    test "(+ +inf.0 -inf.0) is NaN" do
      assert run("(+ +inf.0 -inf.0)") == @nan
      assert run("(+ -inf.0 +inf.0)") == @nan
      assert run("(- +inf.0 +inf.0)") == @nan
    end

    test "infinity + finite preserves the infinity" do
      assert run("(+ +inf.0 1000)") == @pos_inf
      assert run("(+ -inf.0 1000)") == @neg_inf
      assert run("(- +inf.0 1000)") == @pos_inf
    end

    test "(* +inf.0 0) and (* +inf.0 0.0) are NaN" do
      assert run("(* +inf.0 0)") == @nan
      assert run("(* +inf.0 0.0)") == @nan
      assert run("(* 0 -inf.0)") == @nan
    end

    test "(* +inf.0 +inf.0) is +inf.0; (* +inf.0 -inf.0) is -inf.0" do
      assert run("(* +inf.0 +inf.0)") == @pos_inf
      assert run("(* -inf.0 -inf.0)") == @pos_inf
      assert run("(* +inf.0 -inf.0)") == @neg_inf
    end

    test "infinity times finite — sign is product of signs" do
      assert run("(* +inf.0 2)") == @pos_inf
      assert run("(* +inf.0 -2)") == @neg_inf
      assert run("(* -inf.0 -2.0)") == @pos_inf
    end

    test "unary minus negates an infinity, leaves NaN" do
      assert run("(- +inf.0)") == @neg_inf
      assert run("(- -inf.0)") == @pos_inf
      assert run("(- +nan.0)") == @nan
    end

    test "abs of specials" do
      assert run("(abs +inf.0)") == @pos_inf
      assert run("(abs -inf.0)") == @pos_inf
      assert run("(abs +nan.0)") == @nan
    end
  end

  # ---------------------------------------------------------------------------
  # Non-finite floats — division by zero
  # ---------------------------------------------------------------------------

  describe "non-finite division" do
    @pos_inf {:float_special, :pos_inf}
    @neg_inf {:float_special, :neg_inf}
    @nan {:float_special, :nan}

    test "exact integer divisor of zero still raises (r7rs ticket 367)" do
      e = assert_raise PError, fn -> run("(/ 1 0)") end
      assert e.reason == {:division_by_zero, "/"}
    end

    test "finite float over +0.0 yields signed infinity" do
      assert run("(/ 1.0 0.0)") == @pos_inf
      assert run("(/ -1.0 0.0)") == @neg_inf
      assert run("(/ 1 0.0)") == @pos_inf
    end

    test "finite float over -0.0 flips the sign" do
      assert run("(/ 1.0 -0.0)") == @neg_inf
      assert run("(/ -1.0 -0.0)") == @pos_inf
    end

    test "(/ 0.0 0.0) is NaN" do
      assert run("(/ 0.0 0.0)") == @nan
      assert run("(/ -0.0 0.0)") == @nan
    end

    test "(/ +inf.0 +inf.0) and other inf/inf forms are NaN" do
      assert run("(/ +inf.0 +inf.0)") == @nan
      assert run("(/ +inf.0 -inf.0)") == @nan
      assert run("(/ -inf.0 -inf.0)") == @nan
    end

    test "finite over infinity is 0.0" do
      assert run("(/ 1.0 +inf.0)") === 0.0
      assert run("(/ 5 -inf.0)") === 0.0
    end

    test "infinity over finite preserves sign" do
      assert run("(/ +inf.0 2)") == @pos_inf
      assert run("(/ +inf.0 -2)") == @neg_inf
      assert run("(/ -inf.0 -2.0)") == @pos_inf
    end
  end

  # ---------------------------------------------------------------------------
  # Non-finite floats — comparison
  # ---------------------------------------------------------------------------

  describe "non-finite comparison" do
    test "any comparison involving NaN is #f (IEEE-754 unordered)" do
      assert run("(< +nan.0 1)") == Value.bool(false)
      assert run("(< 1 +nan.0)") == Value.bool(false)
      assert run("(> +nan.0 1)") == Value.bool(false)
      assert run("(<= +nan.0 +inf.0)") == Value.bool(false)
      assert run("(>= +nan.0 +nan.0)") == Value.bool(false)
      assert run("(= +nan.0 +nan.0)") == Value.bool(false)
      assert run("(= +nan.0 1)") == Value.bool(false)
    end

    test "+inf.0 is greater than every finite real" do
      assert run("(> +inf.0 1)") == Value.bool(true)
      assert run("(> +inf.0 1.0)") == Value.bool(true)
      assert run("(> +inf.0 1000000000000000000000)") == Value.bool(true)
      assert run("(< 1 +inf.0)") == Value.bool(true)
    end

    test "-inf.0 is less than every finite real" do
      assert run("(< -inf.0 -1)") == Value.bool(true)
      assert run("(< -inf.0 -1000000000000000000000)") == Value.bool(true)
      assert run("(> -1 -inf.0)") == Value.bool(true)
    end

    test "= between like specials (other than NaN) holds" do
      assert run("(= +inf.0 +inf.0)") == Value.bool(true)
      assert run("(= -inf.0 -inf.0)") == Value.bool(true)
      assert run("(= +inf.0 -inf.0)") == Value.bool(false)
    end

    test "<= and >= follow ordinary rules between specials" do
      assert run("(< -inf.0 +inf.0)") == Value.bool(true)
      assert run("(<= -inf.0 +inf.0)") == Value.bool(true)
      assert run("(<= +inf.0 +inf.0)") == Value.bool(true)
      assert run("(>= +inf.0 1)") == Value.bool(true)
    end
  end

  # ---------------------------------------------------------------------------
  # Non-finite floats — predicates
  # ---------------------------------------------------------------------------

  describe "non-finite predicates" do
    test "type predicates classify specials as inexact, non-integer numbers" do
      for lit <- ["+inf.0", "-inf.0", "+nan.0"] do
        assert run("(number? #{lit})") == Value.bool(true)
        assert run("(inexact? #{lit})") == Value.bool(true)
        assert run("(exact? #{lit})") == Value.bool(false)
        assert run("(integer? #{lit})") == Value.bool(false)
      end
    end

    test "zero? is false for all specials" do
      assert run("(zero? +inf.0)") == Value.bool(false)
      assert run("(zero? -inf.0)") == Value.bool(false)
      assert run("(zero? +nan.0)") == Value.bool(false)
    end

    test "positive?/negative? per spec" do
      assert run("(positive? +inf.0)") == Value.bool(true)
      assert run("(positive? -inf.0)") == Value.bool(false)
      assert run("(positive? +nan.0)") == Value.bool(false)
      assert run("(negative? -inf.0)") == Value.bool(true)
      assert run("(negative? +inf.0)") == Value.bool(false)
      assert run("(negative? +nan.0)") == Value.bool(false)
    end

    test "odd?/even? raise — specials are not integers" do
      for lit <- ["+inf.0", "-inf.0", "+nan.0"] do
        assert_raise PError, fn -> run("(odd? #{lit})") end
        assert_raise PError, fn -> run("(even? #{lit})") end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Non-finite floats — min/max/expt/sqrt/exact-inexact
  # ---------------------------------------------------------------------------

  describe "non-finite min/max/expt/sqrt/exact-inexact" do
    @pos_inf {:float_special, :pos_inf}
    @neg_inf {:float_special, :neg_inf}
    @nan {:float_special, :nan}

    test "min/max with NaN propagate NaN" do
      assert run("(min +nan.0 1 2)") == @nan
      assert run("(max 1 +nan.0 2)") == @nan
    end

    test "min/max with infinities" do
      assert run("(max 1 2 +inf.0)") == @pos_inf
      assert run("(min 1 2 -inf.0)") == @neg_inf
      assert run("(min 1 +inf.0)") === 1.0
      assert run("(max -inf.0 -1)") === -1.0
    end

    test "sqrt of specials" do
      assert run("(sqrt +inf.0)") == @pos_inf
      assert run("(sqrt -inf.0)") == @nan
      assert run("(sqrt +nan.0)") == @nan
    end

    test "expt with infinities" do
      assert run("(expt +inf.0 2)") == @pos_inf
      assert run("(expt +inf.0 -2)") === 0.0
      assert run("(expt 2 +inf.0)") == @pos_inf
      assert run("(expt 0.5 +inf.0)") === 0.0
      assert run("(expt 2 -inf.0)") === 0.0
      assert run("(expt 0.5 -inf.0)") == @pos_inf
    end

    test "expt -inf.0 base preserves sign for odd integer exponents" do
      assert run("(expt -inf.0 3)") == @neg_inf
      assert run("(expt -inf.0 2)") == @pos_inf
      assert run("(expt -inf.0 -3)") === 0.0
    end

    test "expt — anything to the 0 is 1.0; 1 to anything is 1.0" do
      assert run("(expt +inf.0 0)") === 1.0
      assert run("(expt +nan.0 0)") === 1.0
      assert run("(expt 1 +inf.0)") === 1.0
    end

    test "expt with NaN propagates (except the 0 / 1 short-circuits)" do
      assert run("(expt +nan.0 1)") == @nan
      assert run("(expt 2 +nan.0)") == @nan
    end

    test "exact->inexact is identity on specials" do
      assert run("(exact->inexact +inf.0)") == @pos_inf
      assert run("(exact->inexact -inf.0)") == @neg_inf
      assert run("(exact->inexact +nan.0)") == @nan
    end

    test "inexact->exact raises on specials — no exact form" do
      for lit <- ["+inf.0", "-inf.0", "+nan.0"] do
        e = assert_raise PError, fn -> run("(inexact->exact #{lit})") end
        assert match?({:not_representable_exact, _}, e.reason)
      end
    end
  end
end

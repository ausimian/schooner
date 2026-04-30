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
      {"'()", [[]]},
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
      "null?" => [],
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
  # Rational tower interactions and remaining "would require complex/irrational"
  # errors
  # ---------------------------------------------------------------------------

  describe "exact division and rationals" do
    test "(/ 1 3) yields an exact rational" do
      assert run("(/ 1 3)") == {:rational, 1, 3}
    end

    test "(/ 6 3) with exact operands stays exact integer" do
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

    test "(expt 2 -3) on integers yields the exact rational 1/8" do
      assert run("(expt 2 -3)") == {:rational, 1, 8}
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

    test "(expt 0 -1) raises division-by-zero" do
      e = assert_raise PError, fn -> run("(expt 0 -1)") end
      assert e.reason == {:division_by_zero, "expt"}
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

    test "inexact->exact on non-integer float yields exact rational" do
      assert run("(inexact->exact 0.5)") == {:rational, 1, 2}
      assert run("(inexact->exact 1.5)") == {:rational, 3, 2}
    end

    test "inexact->exact on +inf.0 / +nan.0 raises" do
      e = assert_raise PError, fn -> run("(inexact->exact +inf.0)") end
      assert match?({:not_representable_exact, _}, e.reason)
      e = assert_raise PError, fn -> run("(inexact->exact +nan.0)") end
      assert match?({:not_representable_exact, _}, e.reason)
    end

    test "inexact and exact are r7rs aliases for the legacy arrow forms" do
      assert run("(inexact 3)") === 3.0
      assert run("(inexact 3.0)") === 3.0
      assert run("(exact 3.0)") === 3
      assert run("(exact 3)") === 3
    end

    test "inexact alias error message uses the alias name" do
      e = assert_raise PError, fn -> run(~s|(inexact "foo")|) end
      assert match?({:type_error, "inexact", _, _}, e.reason)
    end

    test "exact alias error message uses the alias name" do
      e = assert_raise PError, fn -> run(~s|(exact "foo")|) end
      assert match?({:type_error, "exact", _, _}, e.reason)
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

    test "(/ n) reciprocates" do
      assert run("(/ 1.0)") === 1.0
      assert run("(/ 3)") == {:rational, 1, 3}
      assert run("(/ 1)") === 1
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

  # ---------------------------------------------------------------------------
  # min / max — the *first*-argument special branches
  # ---------------------------------------------------------------------------

  describe "non-finite min/max — first-argument specials" do
    @pos_inf {:float_special, :pos_inf}
    @neg_inf {:float_special, :neg_inf}

    test "(min +inf.0 1) — first-arg pos_inf path" do
      assert run("(min +inf.0 1)") === 1.0
    end

    test "(max +inf.0 1) — first-arg pos_inf path" do
      assert run("(max +inf.0 1)") == @pos_inf
    end

    test "(max 1 -inf.0) — second-arg neg_inf path" do
      assert run("(max 1 -inf.0)") === 1.0
    end

    test "(min 1 +inf.0) and (min -inf.0 1) reach both swapped clauses" do
      assert run("(min -inf.0 1)") == @neg_inf
    end
  end

  # ---------------------------------------------------------------------------
  # expt — exponent-as-zero / unit-base / non-integer-exponent paths
  # ---------------------------------------------------------------------------

  describe "expt edge cases" do
    @pos_inf {:float_special, :pos_inf}
    @neg_inf {:float_special, :neg_inf}
    @nan {:float_special, :nan}

    test "anything to +0.0 / -0.0 is 1.0 (matches both signed-zero clauses)" do
      assert run("(expt +inf.0 0.0)") === 1.0
      assert run("(expt +nan.0 (- 0.0))") === 1.0
    end

    test "1.0 base short-circuits to 1.0 even when exp is special" do
      assert run("(expt 1.0 +inf.0)") === 1.0
    end

    test "(expt +inf.0 +inf.0) and (expt -inf.0 +inf.0) — exp has zero finite-sign" do
      # finite_exp_sign(+inf.0) is 0, so both fall through to the NaN clause.
      assert run("(expt +inf.0 +inf.0)") == @nan
      assert run("(expt -inf.0 +inf.0)") == @nan
    end

    test "(expt -1.0 +inf.0) and (expt -1.0 -inf.0) — |base|==1 hits the NaN tail" do
      assert run("(expt -1.0 +inf.0)") == @nan
      assert run("(expt -1.0 -inf.0)") == @nan
    end

    test "(expt -inf.0 odd-float) preserves the negative sign" do
      assert run("(expt -inf.0 3.0)") == @neg_inf
    end

    test "(expt +inf.0 0.5) — positive float exponent" do
      assert run("(expt +inf.0 0.5)") == @pos_inf
      assert run("(expt +inf.0 -0.5)") === 0.0
    end

    test "(expt 5 0) — int_pow base case" do
      assert run("(expt 5 0)") === 1
    end
  end

  # ---------------------------------------------------------------------------
  # inexact->exact / exact division / sqrt edge cases
  # ---------------------------------------------------------------------------

  describe "exactness conversion edge cases" do
    test "inexact->exact is identity on integers" do
      assert run("(inexact->exact 5)") === 5
    end

    test "inexact->exact rejects non-numbers" do
      e = assert_raise PError, fn -> run(~S|(inexact->exact "abc")|) end
      assert match?({:type_error, "inexact->exact", "number", _}, e.reason)
    end

    test "(sqrt 0) is the exact zero" do
      assert run("(sqrt 0)") === 0
    end
  end

  # ---------------------------------------------------------------------------
  # Mixed-exactness comparisons exercise the `is_float(a) or is_float(b)`
  # branch of every numeric comparator.
  # ---------------------------------------------------------------------------

  describe "mixed-exactness comparison branches" do
    test "<, >, <=, >= all promote one int operand to float" do
      assert run("(< 1 1.5)") == Value.bool(true)
      assert run("(> 2.0 1)") == Value.bool(true)
      assert run("(<= 1 1.0)") == Value.bool(true)
      assert run("(>= 2 1.5)") == Value.bool(true)
      assert run("(<= -inf.0 -inf.0)") == Value.bool(true)
    end
  end

  # ---------------------------------------------------------------------------
  # signum — both negative and zero branches via `modulo`
  # ---------------------------------------------------------------------------

  describe "modulo — exercises every branch of signum/1" do
    test "(modulo 0 5) hits the zero branch" do
      assert run("(modulo 0 5)") === 0
    end

    test "(modulo 5 -3) — negative divisor adjusts the result" do
      assert run("(modulo 5 -3)") === -1
    end
  end

  # ---------------------------------------------------------------------------
  # do_member / do_assoc — improper list and bad alist entry
  # ---------------------------------------------------------------------------

  describe "member / assoc on malformed lists" do
    test "member raises :improper_list when the search runs off a dotted tail" do
      e = assert_raise PError, fn -> run("(member 9 '(1 2 . 3))") end
      assert match?({:improper_list, "member", _}, e.reason)
    end

    test "assoc raises type_error for a non-pair entry" do
      e = assert_raise PError, fn -> run("(assoc 9 '((1 . a) 2 (3 . c)))") end
      assert match?({:type_error, "assoc", "pair as alist entry", _}, e.reason)
    end

    test "assoc raises :improper_list when the alist itself is dotted" do
      e = assert_raise PError, fn -> run("(assoc 9 '((1 . a) . 3))") end
      assert match?({:improper_list, "assoc", _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Type errors on primitives that take a single non-aggregate first arg
  # ---------------------------------------------------------------------------

  describe "type errors on aggregates" do
    test "vector ops reject non-vector arg" do
      for {op, src} <- [
            {"vector-length", "(vector-length 1)"},
            {"vector-ref", "(vector-ref 1 0)"},
            {"vector->list", "(vector->list 1)"},
            {"vector-copy", "(vector-copy 1)"}
          ] do
        e = assert_raise PError, fn -> run(src) end
        assert match?({:type_error, ^op, "vector", _}, e.reason)
      end
    end

    test "make-vector with too many args" do
      e = assert_raise PError, fn -> run("(make-vector 3 0 0)") end
      assert match?({:type_error, "make-vector", "1 or 2 arguments", :too_many}, e.reason)
    end

    test "bytevector ops reject non-bytevector arg" do
      for {op, src} <- [
            {"bytevector-length", "(bytevector-length 1)"},
            {"bytevector-u8-ref", "(bytevector-u8-ref 1 0)"},
            {"bytevector-copy", "(bytevector-copy 1)"},
            {"utf8->string", "(utf8->string 1)"},
            {"bytevector-append", "(bytevector-append 1)"}
          ] do
        e = assert_raise PError, fn -> run(src) end
        assert match?({:type_error, ^op, "bytevector", _}, e.reason)
      end
    end

    test "make-bytevector / bytevector-copy / utf8->string with too many args" do
      for {op, src} <- [
            {"make-bytevector", "(make-bytevector 3 0 0)"},
            {"bytevector-copy", "(bytevector-copy #u8(1 2 3) 0 1 2)"},
            {"utf8->string", "(utf8->string #u8(1) 0 1 2)"},
            {"string->utf8", ~S|(string->utf8 "x" 0 1 2)|}
          ] do
        e = assert_raise PError, fn -> run(src) end
        assert match?({:type_error, ^op, _, :too_many}, e.reason)
      end
    end

    test "string->utf8 rejects non-string arg" do
      e = assert_raise PError, fn -> run("(string->utf8 1)") end
      assert match?({:type_error, "string->utf8", "string", _}, e.reason)
    end

    test "string ops reject non-string arg" do
      for {op, src} <- [
            {"string-length", "(string-length 1)"},
            {"string-ref", "(string-ref 1 0)"},
            {"substring", "(substring 1 0 0)"},
            {"string->list", "(string->list 1)"},
            {"string-upcase", "(string-upcase 1)"},
            {"string-downcase", "(string-downcase 1)"},
            {"string-copy", "(string-copy 1)"}
          ] do
        e = assert_raise PError, fn -> run(src) end
        assert match?({:type_error, ^op, "string", _}, e.reason)
      end
    end

    test "make-string / string-copy / string->list with too many args" do
      for {op, src} <- [
            {"make-string", ~S|(make-string 3 #\a #\b)|},
            {"string-copy", ~S|(string-copy "abc" 0 1 2)|},
            {"string->list", ~S|(string->list "abc" 0 1 2)|}
          ] do
        e = assert_raise PError, fn -> run(src) end
        assert match?({:type_error, ^op, _, :too_many}, e.reason)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The 2-arg forms of bytevector-copy / utf8->string / string->utf8 /
  # string->list / string-copy reach the `[v, start]` clause specifically.
  # ---------------------------------------------------------------------------

  describe "two-argument start-only slice forms" do
    test "bytevector-copy with start only" do
      assert run("(bytevector-copy #u8(1 2 3 4) 1)") == Value.bytevector(<<2, 3, 4>>)
    end

    test "utf8->string / string->utf8 with start only" do
      assert run("(utf8->string #u8(97 98 99) 1)") == Value.string("bc")
      assert run(~S|(string->utf8 "abc" 1)|) == Value.bytevector(<<?b, ?c>>)
    end

    test "string->list with start only" do
      assert run(~S|(string->list "abcd" 2)|) == Value.list([Value.char(?c), Value.char(?d)])
    end
  end

  # ---------------------------------------------------------------------------
  # Improper-list inputs to list->vector / list->string — exercises
  # do_scheme_list_to_elixir's improper_list clause.
  # ---------------------------------------------------------------------------

  describe "list->vector / list->string on improper lists" do
    test "list->vector raises :improper_list" do
      e = assert_raise PError, fn -> run("(list->vector '(1 2 . 3))") end
      assert match?({:improper_list, "list->vector", _}, e.reason)
    end

    test "list->string raises :improper_list" do
      e = assert_raise PError, fn -> run(~S|(list->string '(#\a . #\b))|) end
      assert match?({:improper_list, "list->string", _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Off-the-end range failures for substring / string->list / string-copy
  # exercise the `:end` raise paths in slice_codepoints and collect_n.
  # ---------------------------------------------------------------------------

  describe "string slice off-the-end failures" do
    test "substring with start past the end" do
      e = assert_raise PError, fn -> run(~S|(substring "abc" 5 5)|) end
      assert match?({:index_out_of_range, "substring", _, _}, e.reason)
    end

    test "string->list with start past the end" do
      e = assert_raise PError, fn -> run(~S|(string->list "abc" 5)|) end
      assert match?({:index_out_of_range, "string->list", _, _}, e.reason)
    end

    test "string->list with stop past the end (collect_n exhausts source)" do
      e = assert_raise PError, fn -> run(~S|(string->list "abc" 0 10)|) end
      assert match?({:index_out_of_range, "string->list", _, _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Variadic copy/conversion primitives reject 4+ args distinctly so the
  # error names "1 to 3 arguments" rather than landing in the underlying
  # range function with garbage extras.
  # ---------------------------------------------------------------------------

  describe "1-to-3-argument primitives reject too many args" do
    test "vector-copy with 4 args" do
      e = assert_raise PError, fn -> run("(vector-copy #(1 2 3) 0 3 99)") end
      assert e.reason == {:type_error, "vector-copy", "1 to 3 arguments", :too_many}
    end

    test "bytevector-copy with 4 args" do
      e = assert_raise PError, fn -> run("(bytevector-copy #u8(1 2 3) 0 3 99)") end
      assert e.reason == {:type_error, "bytevector-copy", "1 to 3 arguments", :too_many}
    end

    test "utf8->string with 4 args" do
      e = assert_raise PError, fn -> run("(utf8->string #u8(97 98 99) 0 3 99)") end
      assert e.reason == {:type_error, "utf8->string", "1 to 3 arguments", :too_many}
    end

    test "string->utf8 with 4 args" do
      e = assert_raise PError, fn -> run(~S|(string->utf8 "abc" 0 3 99)|) end
      assert e.reason == {:type_error, "string->utf8", "1 to 3 arguments", :too_many}
    end
  end

  describe "utf8->string / string->utf8 with start-only and start+end" do
    test "utf8->string with explicit start and end" do
      assert run("(utf8->string #u8(97 98 99 100) 1 3)") == Value.string("bc")
    end

    test "string->utf8 with explicit start and end" do
      assert run(~S|(string->utf8 "abcd" 1 3)|) == Value.bytevector(<<?b, ?c>>)
    end
  end

  # ---------------------------------------------------------------------------
  # signed-zero, expt -1^even, and -0/-0 = NaN exercise the remaining
  # arithmetic edge cases.
  # ---------------------------------------------------------------------------

  describe "signed-zero arithmetic edges" do
    test "(-1) raised to an even integer is exactly 1" do
      assert run("(expt -1 4)") === 1
    end

    test "(-1) raised to an odd integer is exactly -1" do
      assert run("(expt -1 3)") === -1
    end

    test "+inf.0 multiplied by -0.0 is NaN (sign_finite hits its -0.0 clause)" do
      assert run("(* +inf.0 -0.0)") == {:float_special, :nan}
    end

    test "(-0.0) divided by (-0.0) is NaN" do
      assert run("(/ -0.0 -0.0)") == {:float_special, :nan}
    end

    test "+inf.0 + +inf.0 stays +inf.0 (special_add same-key clause)" do
      assert run("(+ +inf.0 +inf.0)") == {:float_special, :pos_inf}
      assert run("(+ -inf.0 -inf.0)") == {:float_special, :neg_inf}
    end
  end

  describe "char codepoint validation" do
    alias Schooner.Value, as: V

    defp string_primitive do
      {_, _, fun} = Enum.find(Schooner.Primitives.Base.specs(), fn {n, _, _} -> n == "string" end)
      fun
    end

    test "(string c) raises when the char carries a codepoint past 0x10FFFF" do
      bad = V.char(0x110000)

      e = assert_raise PError, fn -> string_primitive().([bad]) end
      assert match?({:codepoint_out_of_range, "char", _}, e.reason)
    end

    test "(string c) raises when the char carries a surrogate codepoint" do
      surrogate = V.char(0xD800)

      e = assert_raise PError, fn -> string_primitive().([surrogate]) end
      assert match?({:codepoint_out_of_range, "char", _}, e.reason)
    end
  end

  describe "multi-value returns" do
    test "(values v) in single-value context returns v unchanged" do
      assert run("(values 42)") == 42
      assert run("(+ (values 5) 10)") == 15
    end

    test "(values) in single-value context errors with wrong-value-count" do
      e = assert_raise PError, fn -> run("(values)") end
      assert match?({:wrong_value_count, 0, 1}, e.reason)
    end

    test "(values v1 v2 ...) in single-value context errors with wrong-value-count" do
      e = assert_raise PError, fn -> run("(values 1 2)") end
      assert match?({:wrong_value_count, 2, 1}, e.reason)
    end

    test "call-with-values routes a single-value producer to a 1-arg consumer" do
      assert run("(call-with-values (lambda () 5) (lambda (x) (* x 2)))") == 10
    end

    test "call-with-values routes a multi-value producer to a multi-arg consumer" do
      assert run("(call-with-values (lambda () (values 1 2 3)) +)") == 6
      assert run("(call-with-values (lambda () (values 4 5)) -)") == -1
    end

    test "call-with-values routes a zero-value producer to a zero-arg consumer" do
      assert run("(call-with-values (lambda () (values)) (lambda () 'ok))") == Value.symbol("ok")
    end

    test "let-values binds multiple values from a single producer" do
      assert run("(let-values (((a b) (values 1 2))) (+ a b))") == 3
    end

    test "let-values with rest formals binds all values to a list" do
      assert run("(let-values ((all (values 1 2 3))) all)") == Value.list([1, 2, 3])
    end

    test "let-values with multiple bindings independently destructures each producer" do
      assert run("""
             (let-values (((a b) (values 1 2))
                          ((c d) (values 3 4)))
               (list a b c d))
             """) == Value.list([1, 2, 3, 4])
    end

    test "let*-values lets later bindings see earlier ones" do
      assert run("""
             (let*-values (((a b) (values 1 2))
                           ((c) (values (+ a b))))
               c)
             """) == 3
    end
  end
end

defmodule Schooner.Primitives.BaseNumericExtraTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  # ---------------------------------------------------------------------------
  # Issue #86 — floor / ceiling / truncate / round
  # ---------------------------------------------------------------------------

  describe "floor / ceiling / truncate / round on integers" do
    test "all four are identity on exact integers" do
      assert run("(floor 0)") === 0
      assert run("(floor -7)") === -7
      assert run("(ceiling 5)") === 5
      assert run("(truncate -3)") === -3
      assert run("(round 4)") === 4
    end
  end

  describe "rounding family on rationals" do
    test "(floor 3/2) = 1, (floor -3/2) = -2 (toward -inf)" do
      assert run("(floor 3/2)") === 1
      assert run("(floor -3/2)") === -2
      assert run("(floor -1/3)") === -1
    end

    test "(ceiling 3/2) = 2, (ceiling -3/2) = -1 (toward +inf)" do
      assert run("(ceiling 3/2)") === 2
      assert run("(ceiling -3/2)") === -1
      assert run("(ceiling 1/3)") === 1
    end

    test "(truncate 3/2) = 1, (truncate -3/2) = -1 (toward zero)" do
      assert run("(truncate 3/2)") === 1
      assert run("(truncate -3/2)") === -1
      assert run("(truncate -1/3)") === 0
    end

    test "(round 7/2) ties to 4, (round 5/2) ties to 2 (banker's)" do
      assert run("(round 7/2)") === 4
      assert run("(round 5/2)") === 2
      assert run("(round -7/2)") === -4
      assert run("(round -5/2)") === -2
    end

    test "(round) on non-tie rationals picks the closer integer" do
      assert run("(round 1/3)") === 0
      assert run("(round 2/3)") === 1
      assert run("(round -1/3)") === 0
      assert run("(round -2/3)") === -1
    end
  end

  describe "rounding family on floats" do
    test "exactness contamination — float input → float result" do
      assert run("(floor 3.7)") === 3.0
      assert run("(ceiling 3.1)") === 4.0
      assert run("(truncate 3.7)") === 3.0
      assert run("(truncate -3.7)") === -3.0
      assert run("(round 3.4)") === 3.0
    end

    test "round on float ties is banker's (to even)" do
      assert run("(round 0.5)") === 0.0
      assert run("(round 1.5)") === 2.0
      assert run("(round 2.5)") === 2.0
      assert run("(round 3.5)") === 4.0
      assert run("(round -0.5)") === 0.0
      assert run("(round -1.5)") === -2.0
      assert run("(round -2.5)") === -2.0
    end
  end

  describe "rounding family on non-finite specials" do
    test "non-finite inputs pass through unchanged" do
      assert run("(floor +inf.0)") === {:float_special, :pos_inf}
      assert run("(ceiling -inf.0)") === {:float_special, :neg_inf}
      assert run("(truncate +nan.0)") === {:float_special, :nan}
      assert run("(round -inf.0)") === {:float_special, :neg_inf}
    end
  end

  describe "rounding family type errors" do
    test "non-real arguments raise type_error" do
      assert_raise PError, fn -> run("(floor 1+2i)") end
      assert_raise PError, fn -> run("(ceiling \"abc\")") end
      assert_raise PError, fn -> run("(round 'sym)") end
      assert_raise PError, fn -> run("(truncate #t)") end
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #87 — floor/ truncate/ and *-quotient / *-remainder pairs
  # ---------------------------------------------------------------------------

  describe "truncate-quotient / truncate-remainder" do
    test "truncate-quotient is r5rs quotient (toward zero)" do
      assert run("(truncate-quotient 13 4)") === 3
      assert run("(truncate-quotient -13 4)") === -3
      assert run("(truncate-quotient 13 -4)") === -3
      assert run("(truncate-quotient -13 -4)") === 3
    end

    test "truncate-remainder agrees with r5rs remainder" do
      assert run("(truncate-remainder 13 4)") === 1
      assert run("(truncate-remainder -13 4)") === -1
      assert run("(truncate-remainder 13 -4)") === 1
      assert run("(truncate-remainder -13 -4)") === -1
    end
  end

  describe "floor-quotient / floor-remainder" do
    test "floor-quotient rounds toward -inf" do
      assert run("(floor-quotient 13 4)") === 3
      assert run("(floor-quotient -13 4)") === -4
      assert run("(floor-quotient 13 -4)") === -4
      assert run("(floor-quotient -13 -4)") === 3
    end

    test "floor-remainder agrees with r5rs modulo" do
      assert run("(floor-remainder 13 4)") === 1
      assert run("(floor-remainder -13 4)") === 3
      assert run("(floor-remainder 13 -4)") === -3
      assert run("(floor-remainder -13 -4)") === -1
    end
  end

  describe "floor/ and truncate/ as multi-value returns" do
    test "(floor/ n d) returns floor-quotient and floor-remainder" do
      assert run("(call-with-values (lambda () (floor/ 13 4)) list)") ==
               Value.list([3, 1])

      assert run("(call-with-values (lambda () (floor/ -13 4)) list)") ==
               Value.list([-4, 3])
    end

    test "(truncate/ n d) returns truncate-quotient and truncate-remainder" do
      assert run("(call-with-values (lambda () (truncate/ 13 4)) list)") ==
               Value.list([3, 1])

      assert run("(call-with-values (lambda () (truncate/ -13 4)) list)") ==
               Value.list([-3, -1])
    end

    test "let-values destructures the pair" do
      assert run("""
             (let-values (((q r) (floor/ -13 4)))
               (+ (* 100 q) r))
             """) === -397
    end
  end

  describe "division-family contamination + zero divisor" do
    test "any float operand contaminates the result" do
      assert run("(floor-quotient 7 3.0)") === 2.0
      assert run("(floor-remainder 7.0 3)") === 1.0
      assert run("(truncate-quotient 7 3.0)") === 2.0
      assert run("(truncate-remainder 7.0 3)") === 1.0
    end

    test "division by zero raises in every variant" do
      for op <- ~w(truncate-quotient truncate-remainder floor-quotient floor-remainder),
          do: assert_raise(PError, fn -> run("(#{op} 5 0)") end)

      for op <- ~w(truncate/ floor/),
          do: assert_raise(PError, fn -> run("(#{op} 5 0)") end)
    end

    test "non-integer operands raise type_error" do
      assert_raise PError, fn -> run("(floor-quotient 5/2 1)") end
      assert_raise PError, fn -> run("(truncate-remainder 1.5 1)") end
      assert_raise PError, fn -> run("(floor/ 1+2i 1)") end
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #88 — square / exact-integer-sqrt / exact-integer? / exact-rational?
  # ---------------------------------------------------------------------------

  describe "square" do
    test "square is (* z z) and follows exactness" do
      assert run("(square 5)") === 25
      assert run("(square -3)") === 9
      assert run("(square 5.0)") === 25.0
      assert run("(square 1/2)") === Value.rational(1, 4)
      assert run("(square 0)") === 0
    end

    test "square works on complex" do
      assert run("(square 1+2i)") === Value.complex(-3, 4)
      assert run("(square 0+1i)") === -1
    end

    test "(square +nan.0) is +nan.0" do
      assert run("(square +nan.0)") === {:float_special, :nan}
    end

    test "non-number raises type_error" do
      assert_raise PError, fn -> run("(square \"abc\")") end
    end
  end

  describe "exact-integer-sqrt" do
    test "(exact-integer-sqrt k) returns (s r) with k = s^2 + r and (s+1)^2 > k" do
      assert run("(call-with-values (lambda () (exact-integer-sqrt 17)) list)") ==
               Value.list([4, 1])

      assert run("(call-with-values (lambda () (exact-integer-sqrt 16)) list)") ==
               Value.list([4, 0])

      assert run("(call-with-values (lambda () (exact-integer-sqrt 0)) list)") ==
               Value.list([0, 0])

      assert run("(call-with-values (lambda () (exact-integer-sqrt 1)) list)") ==
               Value.list([1, 0])
    end

    test "handles arbitrary-precision integers" do
      assert run("""
             (call-with-values
               (lambda () (exact-integer-sqrt 100000000000000000000))
               list)
             """) ==
               Value.list([10_000_000_000, 0])
    end

    test "rejects negatives, floats, and non-numbers" do
      assert_raise PError, fn -> run("(exact-integer-sqrt -1)") end
      assert_raise PError, fn -> run("(exact-integer-sqrt 1.0)") end
      assert_raise PError, fn -> run("(exact-integer-sqrt 1/2)") end
      assert_raise PError, fn -> run("(exact-integer-sqrt \"abc\")") end
    end
  end

  describe "exact-integer? / exact-rational?" do
    test "exact-integer? is true only for exact integers" do
      assert run("(exact-integer? 0)") === true
      assert run("(exact-integer? 5)") === true
      assert run("(exact-integer? -5)") === true
      assert run("(exact-integer? 5.0)") === false
      assert run("(exact-integer? 1/2)") === false
      assert run("(exact-integer? 1+2i)") === false
      assert run("(exact-integer? +inf.0)") === false
      assert run("(exact-integer? \"5\")") === false
    end

    test "exact-rational? is true for exact integers and exact rationals" do
      assert run("(exact-rational? 5)") === true
      assert run("(exact-rational? 1/2)") === true
      assert run("(exact-rational? -3/4)") === true
      assert run("(exact-rational? 1.5)") === false
      assert run("(exact-rational? +inf.0)") === false
      assert run("(exact-rational? 1+2i)") === false
      assert run("(exact-rational? \"x\")") === false
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #89 — number->string / string->number
  # ---------------------------------------------------------------------------

  describe "number->string default radix 10" do
    test "exact integers, rationals, floats, specials, complex" do
      assert run("(number->string 0)") == "0"
      assert run("(number->string 100)") == "100"
      assert run("(number->string -42)") == "-42"
      assert run("(number->string 1/2)") == "1/2"
      assert run("(number->string -3/4)") == "-3/4"
      assert run("(number->string 3.14)") == "3.14"
      assert run("(number->string +inf.0)") == "+inf.0"
      assert run("(number->string -inf.0)") == "-inf.0"
      assert run("(number->string +nan.0)") == "+nan.0"
      assert run("(number->string 1+2i)") == "1+2i"
      assert run("(number->string +i)") == "+i"
    end
  end

  describe "number->string with explicit radix" do
    test "exact integers in every radix" do
      assert run("(number->string 100 2)") == "1100100"
      assert run("(number->string 100 8)") == "144"
      assert run("(number->string 100 10)") == "100"
      assert run("(number->string 100 16)") == "64"
      assert run("(number->string 255 16)") == "ff"
      assert run("(number->string -255 16)") == "-ff"
    end

    test "exact rationals in non-decimal radix" do
      assert run("(number->string 1/2 2)") == "1/10"
      assert run("(number->string 255/16 16)") == "ff/10"
    end

    test "exact complex numbers in non-decimal radix" do
      assert run("(number->string 16+255i 16)") == "10+ffi"
    end

    test "inexact + non-decimal radix raises" do
      assert_raise PError, fn -> run("(number->string 3.14 2)") end
      assert_raise PError, fn -> run("(number->string 1.0+2.0i 16)") end
      assert_raise PError, fn -> run("(number->string +inf.0 16)") end
    end

    test "unsupported radix raises" do
      assert_raise PError, fn -> run("(number->string 100 7)") end
    end

    test "non-number argument raises" do
      assert_raise PError, fn -> run("(number->string \"100\")") end
    end
  end

  describe "string->number" do
    test "exact integer literals (default radix 10)" do
      assert run(~s|(string->number "0")|) === 0
      assert run(~s|(string->number "100")|) === 100
      assert run(~s|(string->number "-42")|) === -42
      assert run(~s|(string->number "+7")|) === 7
    end

    test "exact rationals and floats" do
      assert run(~s|(string->number "1/2")|) === Value.rational(1, 2)
      assert run(~s|(string->number "-3/4")|) === Value.rational(-3, 4)
      assert run(~s|(string->number "3.14")|) === 3.14
      assert run(~s|(string->number "1e2")|) === 100.0
    end

    test "non-finite specials" do
      assert run(~s|(string->number "+inf.0")|) === {:float_special, :pos_inf}
      assert run(~s|(string->number "-inf.0")|) === {:float_special, :neg_inf}
      assert run(~s|(string->number "+nan.0")|) === {:float_special, :nan}
    end

    test "rectangular complex" do
      assert run(~s|(string->number "1+2i")|) === Value.complex(1, 2)
      assert run(~s|(string->number "+i")|) === Value.complex(0, 1)
      assert run(~s|(string->number "-i")|) === Value.complex(0, -1)
    end

    test "with supplied radix" do
      assert run(~s|(string->number "100" 2)|) === 4
      assert run(~s|(string->number "100" 8)|) === 64
      assert run(~s|(string->number "100" 16)|) === 256
      assert run(~s|(string->number "ff" 16)|) === 255
      assert run(~s|(string->number "-ff" 16)|) === -255
    end

    test "explicit prefix in string overrides supplied radix" do
      assert run(~s|(string->number "#x10" 2)|) === 16
      assert run(~s|(string->number "#b10" 16)|) === 2
    end

    test "exactness prefix in string is honoured" do
      assert run(~s|(string->number "#i100")|) === 100.0
    end

    test "invalid input returns #f, never raises" do
      assert run(~s|(string->number "")|) === false
      assert run(~s|(string->number "abc")|) === false
      assert run(~s|(string->number "3 ")|) === false
      assert run(~s|(string->number " 3")|) === false
      assert run(~s|(string->number "3 4")|) === false
      assert run(~s|(string->number "(1 2)")|) === false
      assert run(~s|(string->number "100" 16) "g"|) != run(~s|(string->number "g" 16)|)
      assert run(~s|(string->number "g" 16)|) === false
      assert run(~s|(string->number "12" 8)|) === 10
      assert run(~s|(string->number "9" 8)|) === false
    end

    test "unsupported radix raises (consistent with number->string)" do
      assert_raise PError, fn -> run(~s|(string->number "100" 7)|) end
    end

    test "non-string first argument raises type_error" do
      assert_raise PError, fn -> run("(string->number 100)") end
    end
  end

  describe "round-trip via number->string and string->number" do
    test "exact integers and rationals round-trip in each radix" do
      for value <- ["0", "1", "-1", "1024", "-1024", "1/2", "-3/7", "65535"] do
        assert run("""
               (let ((n (string->number #{inspect(value)})))
                 (= n (string->number (number->string n))))
               """) === true
      end
    end

    test "specials and complex literals round-trip via radix 10" do
      for value <- ["+inf.0", "-inf.0", "1+2i", "+i", "-i", "0.5"] do
        assert run("""
               (let ((n (string->number #{inspect(value)})))
                 (string->number (number->string n)))
               """) === run(~s|(string->number #{inspect(value)})|)
      end
    end

    test "round-trip via radix 16" do
      assert run("""
             (let ((n 65535)) (= n (string->number (number->string n 16) 16)))
             """) === true
    end
  end
end

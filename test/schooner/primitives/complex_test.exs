defmodule Schooner.Primitives.ComplexTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)
  defp pi, do: :math.pi()

  # ---------------------------------------------------------------------------
  # Reader and writer for the rectangular / polar external representation
  # ---------------------------------------------------------------------------

  describe "reader and writer" do
    test "rectangular literal with positive imag" do
      assert run("(quote 3+4i)") == {:complex, 3, 4}
    end

    test "rectangular literal with negative imag" do
      assert run("(quote 3-4i)") == {:complex, 3, -4}
    end

    test "rectangular literal with floats" do
      assert run("(quote -2.5-1.0i)") == {:complex, -2.5, -1.0}
    end

    test "unit imaginary" do
      assert run("(quote +i)") == {:complex, 0, 1}
      assert run("(quote -i)") == {:complex, 0, -1}
    end

    test "unit imaginary with explicit real" do
      assert run("(quote 5+i)") == {:complex, 5, 1}
      assert run("(quote 5-i)") == {:complex, 5, -1}
    end

    test "rational components" do
      assert run("(quote 1/2+3/4i)") == {:complex, {:rational, 1, 2}, {:rational, 3, 4}}
    end

    test "exponent in real part doesn't trip the imag-sign scan" do
      assert run("(quote 1.0e-3+2i)") == {:complex, 1.0e-3, 2}
    end

    test "polar form converts to rectangular" do
      {:complex, r, i} = run("(quote 1@0)")
      assert_in_delta r, 1.0, 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    test "polar form (1@π/2) is approximately +i" do
      {:complex, r, i} = run("(quote 1@1.5707963267948966)")
      assert_in_delta r, 0.0, 1.0e-12
      assert_in_delta i, 1.0, 1.0e-12
    end

    test "imaginary 0i collapses to real on construction via reader" do
      # `3+0i` is real per r7rs: imag exact 0 ⇒ collapse.
      assert run("(quote 3+0i)") === 3
    end

    test "writer round-trips rectangular" do
      assert Value.write({:complex, 3, 4}) == "3+4i"
      assert Value.write({:complex, 3, -4}) == "3-4i"
      assert Value.write({:complex, -2.5, -1.0}) == "-2.5-1.0i"
    end

    test "writer renders unit imag as +i / -i" do
      assert Value.write({:complex, 0, 1}) == "+i"
      assert Value.write({:complex, 0, -1}) == "-i"
      assert Value.write({:complex, 5, 1}) == "5+i"
      assert Value.write({:complex, 5, -1}) == "5-i"
    end

    test "writer renders an inexact zero real explicitly" do
      assert Value.write({:complex, 0.0, 1.0}) == "0.0+1.0i"
    end
  end

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  describe "predicates" do
    test "complex? is #t for every number" do
      assert run("(complex? 1)") == Value.bool(true)
      assert run("(complex? 1/2)") == Value.bool(true)
      assert run("(complex? 1.5)") == Value.bool(true)
      assert run("(complex? 3+4i)") == Value.bool(true)
      assert run("(complex? +nan.0)") == Value.bool(true)
    end

    test "complex? is #f for non-numbers" do
      assert run("(complex? 'foo)") == Value.bool(false)
      assert run(~S|(complex? "1")|) == Value.bool(false)
    end

    test "real? is #f for tagged complex" do
      assert run("(real? 3+4i)") == Value.bool(false)
      assert run("(real? +i)") == Value.bool(false)
    end

    test "real? is #t for real-valued numbers" do
      assert run("(real? 3)") == Value.bool(true)
      assert run("(real? 3.0)") == Value.bool(true)
      assert run("(real? 1/2)") == Value.bool(true)
      assert run("(real? +inf.0)") == Value.bool(true)
    end

    test "real? is #t when imag part is exact 0 (collapses)" do
      # `3+0i` collapses on read to bare 3.
      assert run("(real? 3+0i)") == Value.bool(true)
    end

    test "real? is #f when imag part is inexact zero" do
      assert run("(real? 3.0+0.0i)") == Value.bool(false)
    end

    test "number? agrees with complex?" do
      assert run("(number? 3+4i)") == Value.bool(true)
    end

    test "rational? is #f for tagged complex" do
      assert run("(rational? 3+4i)") == Value.bool(false)
    end

    test "integer? is #f for tagged complex" do
      assert run("(integer? 3+4i)") == Value.bool(false)
    end

    test "exact? is #t when both parts exact" do
      assert run("(exact? 3+4i)") == Value.bool(true)
      assert run("(exact? 1/2+3/4i)") == Value.bool(true)
    end

    test "inexact? is #t when either part inexact" do
      assert run("(inexact? 3.0+4i)") == Value.bool(true)
      assert run("(inexact? 3+4.0i)") == Value.bool(true)
      assert run("(inexact? 3.0+4.0i)") == Value.bool(true)
    end

    test "zero? is #t only when both parts numerically zero" do
      assert run("(zero? 0.0+0.0i)") == Value.bool(true)
      assert run("(zero? 0+1i)") == Value.bool(false)
    end
  end

  # ---------------------------------------------------------------------------
  # Library procedures: make-rectangular, make-polar, real-part, imag-part,
  # magnitude, angle
  # ---------------------------------------------------------------------------

  describe "make-rectangular" do
    test "exact components" do
      assert run("(make-rectangular 3 4)") == {:complex, 3, 4}
    end

    test "exact zero imag collapses" do
      assert run("(make-rectangular 1.0 0)") === 1.0
      assert run("(make-rectangular 5 0)") === 5
    end

    test "inexact zero imag does not collapse" do
      assert run("(make-rectangular 1.0 0.0)") == {:complex, 1.0, 0.0}
    end

    test "rational components" do
      assert run("(make-rectangular 1/2 -3/4)") ==
               {:complex, {:rational, 1, 2}, {:rational, -3, 4}}
    end

    test "rejects non-real real-part" do
      e = assert_raise PError, fn -> run("(make-rectangular 1+2i 3)") end
      assert match?({:type_error, "make-rectangular", _, _}, e.reason)
    end
  end

  describe "make-polar" do
    test "magnitude 0 → 0" do
      assert run("(make-polar 0 1.5)") == {:complex, 0.0, 0.0}
    end

    test "angle 0 → real" do
      {:complex, r, i} = run("(make-polar 5 0)")
      assert_in_delta r, 5.0, 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    test "angle π → -mag (negative real)" do
      {:complex, r, i} = run("(make-polar 1 #{pi()})")
      assert_in_delta r, -1.0, 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    test "angle π/2 → mag * i" do
      {:complex, r, i} = run("(make-polar 2 1.5707963267948966)")
      assert_in_delta r, 0.0, 1.0e-12
      assert_in_delta i, 2.0, 1.0e-12
    end

    test "non-finite operand rejected" do
      e = assert_raise PError, fn -> run("(make-polar +inf.0 0)") end
      assert match?({:type_error, "make-polar", _, _}, e.reason)

      e = assert_raise PError, fn -> run("(make-polar 1 +nan.0)") end
      assert match?({:type_error, "make-polar", _, _}, e.reason)
    end

    test "rational magnitude/angle flow through the rational coercion" do
      {:complex, r, i} = run("(make-polar 1/2 0)")
      assert_in_delta r, 0.5, 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    test "non-number operand rejected with type-error" do
      e = assert_raise PError, fn -> run(~s|(make-polar "x" 0)|) end
      assert match?({:type_error, "make-polar", _, _}, e.reason)
    end
  end

  describe "real-part / imag-part" do
    test "selectors on rectangular complex" do
      assert run("(real-part 3+4i)") === 3
      assert run("(imag-part 3+4i)") === 4
    end

    test "selectors on float complex" do
      assert run("(real-part 1.5+2.5i)") === 1.5
      assert run("(imag-part 1.5+2.5i)") === 2.5
    end

    test "selectors on a real return matched exactness" do
      assert run("(real-part 5)") === 5
      assert run("(imag-part 5)") === 0
      assert run("(real-part 5.0)") === 5.0
      assert run("(imag-part 5.0)") === 0.0
    end

    test "selectors on rationals" do
      assert run("(real-part 1/2)") == {:rational, 1, 2}
      assert run("(imag-part 1/2)") === 0
    end

    test "imag-part on a non-finite real is inexact zero" do
      assert run("(imag-part +inf.0)") === 0.0
      assert run("(imag-part -inf.0)") === 0.0
      assert run("(imag-part +nan.0)") === 0.0
    end

    test "selectors reject non-numbers" do
      e = assert_raise PError, fn -> run("(real-part 'foo)") end
      assert match?({:type_error, "real-part", _, _}, e.reason)

      e = assert_raise PError, fn -> run("(imag-part 'foo)") end
      assert match?({:type_error, "imag-part", _, _}, e.reason)
    end
  end

  describe "magnitude" do
    test "|3+4i| = 5" do
      assert run("(magnitude 3+4i)") === 5.0
    end

    test "|1+i| = sqrt 2" do
      assert run("(magnitude 1+i)") == :math.sqrt(2.0)
    end

    test "|float complex| flows through float-component path" do
      assert_in_delta run("(magnitude 1.5+2.5i)"), :math.sqrt(1.5 * 1.5 + 2.5 * 2.5), 1.0e-12
    end

    test "|rational complex| flows through rational-component path" do
      # |1/2 + 1/2 i| = sqrt(1/2)
      assert_in_delta run("(magnitude 1/2+1/2i)"), :math.sqrt(0.5), 1.0e-12
    end

    test "magnitude of a real is its absolute value" do
      assert run("(magnitude -7)") === 7
      assert run("(magnitude 1/2)") == {:rational, 1, 2}
      assert run("(magnitude -1/2)") == {:rational, 1, 2}
      assert run("(magnitude -inf.0)") == {:float_special, :pos_inf}
      assert run("(magnitude +inf.0)") == {:float_special, :pos_inf}
      assert run("(magnitude +nan.0)") == {:float_special, :nan}
    end

    test "magnitude with infinite component is +inf" do
      assert run("(magnitude (make-rectangular +inf.0 5))") == {:float_special, :pos_inf}
    end

    test "magnitude with NaN component propagates NaN" do
      assert run("(magnitude (make-rectangular +nan.0 5))") == {:float_special, :nan}
    end

    test "magnitude rejects non-numbers" do
      e = assert_raise PError, fn -> run("(magnitude 'foo)") end
      assert match?({:type_error, "magnitude", _, _}, e.reason)
    end
  end

  describe "angle" do
    test "angle of a positive real is 0" do
      assert run("(angle 5)") === 0
      assert run("(angle 1.5)") === 0.0
    end

    test "angle of a negative real is π" do
      assert run("(angle -5)") == pi()
      assert run("(angle -1.5)") == pi()
    end

    test "angle of a positive rational is 0; negative rational is π" do
      assert run("(angle 1/2)") === 0
      assert run("(angle -1/2)") == pi()
    end

    test "angle of non-finite reals" do
      assert run("(angle +inf.0)") === 0.0
      assert run("(angle -inf.0)") == pi()
      assert run("(angle +nan.0)") == {:float_special, :nan}
    end

    test "angle of +i is π/2" do
      assert_in_delta run("(angle +i)"), pi() / 2.0, 1.0e-12
    end

    test "angle of -i is -π/2" do
      assert_in_delta run("(angle -i)"), -pi() / 2.0, 1.0e-12
    end

    test "angle of 1+i is π/4" do
      assert_in_delta run("(angle 1+i)"), pi() / 4.0, 1.0e-12
    end

    test "angle of -1-i is -3π/4" do
      assert_in_delta run("(angle -1-i)"), -3.0 * pi() / 4.0, 1.0e-12
    end

    test "angle with NaN component propagates NaN" do
      assert run("(angle (make-rectangular +nan.0 1))") == {:float_special, :nan}
      assert run("(angle (make-rectangular 1 +nan.0))") == {:float_special, :nan}
    end

    test "angle of (±inf, ±inf) — IEEE-754 atan2 quadrant boundaries" do
      assert_in_delta run("(angle (make-rectangular +inf.0 +inf.0))"), pi() / 4.0, 1.0e-12

      assert_in_delta run("(angle (make-rectangular -inf.0 +inf.0))"),
                      3.0 * pi() / 4.0,
                      1.0e-12

      assert_in_delta run("(angle (make-rectangular +inf.0 -inf.0))"), -pi() / 4.0, 1.0e-12

      assert_in_delta run("(angle (make-rectangular -inf.0 -inf.0))"),
                      -3.0 * pi() / 4.0,
                      1.0e-12
    end

    test "angle with infinite imag, finite real → ±π/2" do
      assert_in_delta run("(angle (make-rectangular 5 +inf.0))"), pi() / 2.0, 1.0e-12
      assert_in_delta run("(angle (make-rectangular 5 -inf.0))"), -pi() / 2.0, 1.0e-12
    end

    test "angle with infinite real, finite imag → 0 / π with sign-of-imag" do
      assert run("(angle (make-rectangular +inf.0 5))") === 0.0
      assert run("(angle (make-rectangular +inf.0 -5))") === -0.0
      assert_in_delta run("(angle (make-rectangular -inf.0 5))"), pi(), 1.0e-12
      assert_in_delta run("(angle (make-rectangular -inf.0 -5))"), -pi(), 1.0e-12
      # rational imag exercises real_negative? for {:rational, ...}
      assert run("(angle (make-rectangular +inf.0 -1/2))") === -0.0
      # float imag exercises real_negative? for is_float
      assert run("(angle (make-rectangular +inf.0 -1.5))") === -0.0
    end

    test "angle rejects non-numbers" do
      e = assert_raise PError, fn -> run("(angle 'foo)") end
      assert match?({:type_error, "angle", _, _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Arithmetic
  # ---------------------------------------------------------------------------

  describe "arithmetic" do
    test "addition" do
      assert run("(+ 1+2i 3+4i)") == {:complex, 4, 6}
      assert run("(+ 1 2+3i)") == {:complex, 3, 3}
      assert run("(+ 2+3i 5)") == {:complex, 7, 3}
    end

    test "subtraction" do
      assert run("(- 5+3i 2+i)") == {:complex, 3, 2}
      assert run("(- 1+i)") == {:complex, -1, -1}
    end

    test "multiplication" do
      # (1+2i)(3+4i) = (3-8) + (4+6)i = -5 + 10i
      assert run("(* 1+2i 3+4i)") == {:complex, -5, 10}
    end

    test "multiplication by i squared = -1 (real)" do
      assert run("(* +i +i)") === -1
    end

    test "division" do
      # (1+2i) / (3+4i) = (11/25) + (2/25)i
      assert run("(/ 1+2i 3+4i)") == {:complex, {:rational, 11, 25}, {:rational, 2, 25}}
    end

    test "reciprocal of i is -i" do
      assert run("(/ +i)") == {:complex, 0, -1}
    end

    test "= compares both rectangular components" do
      assert run("(= 3+4i 3+4i)") == Value.bool(true)
      assert run("(= 3+4i 3+5i)") == Value.bool(false)
      assert run("(= (make-rectangular 1 0) 1)") == Value.bool(true)
    end

    test "real-only comparisons reject complex" do
      for op <- ["<", ">", "<=", ">="] do
        e = assert_raise PError, fn -> run("(#{op} 1 1+2i)") end
        assert match?({:type_error, ^op, "real number", _}, e.reason)
      end
    end

    test "abs rejects complex (use magnitude instead)" do
      e = assert_raise PError, fn -> run("(abs 3+4i)") end
      assert match?({:type_error, "abs", "real number", _}, e.reason)
    end

    test "min / max reject complex" do
      e = assert_raise PError, fn -> run("(min 1 1+2i)") end
      assert match?({:type_error, "min", "real number", _}, e.reason)
    end

    test "positive? / negative? reject complex" do
      e = assert_raise PError, fn -> run("(positive? 1+2i)") end
      assert match?({:type_error, "positive?", "real number", _}, e.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Powers, roots, transcendentals
  # ---------------------------------------------------------------------------

  describe "powers and roots" do
    test "expt with integer exponent on complex base is exact" do
      assert run("(expt 1+i 2)") == {:complex, 0, 2}
      assert run("(expt 1+i 4)") === -4
    end

    test "expt with negative integer on complex base inverts" do
      assert run("(expt +i -1)") == {:complex, 0, -1}
    end

    test "expt 0 = 1" do
      assert run("(expt 1+i 0)") === 1
    end

    test "complex sqrt of -1 is i" do
      assert run("(sqrt -1)") == {:complex, 0, 1.0}
    end

    test "complex sqrt of i" do
      {:complex, r, i} = run("(sqrt +i)")
      assert_in_delta r, :math.sqrt(2.0) / 2.0, 1.0e-12
      assert_in_delta i, :math.sqrt(2.0) / 2.0, 1.0e-12
    end

    test "complex sqrt of -4 is 2i" do
      assert run("(sqrt -4)") == {:complex, 0, 2.0}
    end
  end

  describe "transcendentals" do
    test "log of -1 is iπ" do
      assert run("(log -1)") == {:complex, 0.0, pi()}
    end

    test "exp(iπ) ≈ -1 (Euler)" do
      {:complex, r, i} = run("(exp (make-rectangular 0 #{pi()}))")
      assert_in_delta r, -1.0, 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    test "log(exp(z)) ≈ z for finite z" do
      {:complex, r, i} = run("(log (exp 1+2i))")
      assert_in_delta r, 1.0, 1.0e-12
      assert_in_delta i, 2.0, 1.0e-12
    end

    test "sin(iπ) is i*sinh(π)" do
      {:complex, r, i} = run("(sin (make-rectangular 0 #{pi()}))")
      assert_in_delta r, 0.0, 1.0e-12
      assert_in_delta i, :math.sinh(pi()), 1.0e-12
    end

    test "cos(0+i) = cosh(1)" do
      {:complex, r, i} = run("(cos (make-rectangular 0 1))")
      assert_in_delta r, :math.cosh(1.0), 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    test "sin² + cos² = 1 holds for complex too" do
      # (sin z)^2 + (cos z)^2 should equal 1
      {:complex, r, i} = run("(+ (* (sin 1+i) (sin 1+i)) (* (cos 1+i) (cos 1+i)))")
      assert_in_delta r, 1.0, 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    test "atan(1) ≈ π/4 (real input still real)" do
      assert_in_delta run("(atan 1)"), pi() / 4.0, 1.0e-12
    end

    test "atan(tan z) ≈ z for finite z away from singularities" do
      {:complex, r, i} = run("(atan (tan 0.5+0.3i))")
      assert_in_delta r, 0.5, 1.0e-12
      assert_in_delta i, 0.3, 1.0e-12
    end
  end

  # ---------------------------------------------------------------------------
  # Equality
  # ---------------------------------------------------------------------------

  describe "Value-level equality" do
    test "eqv? on equal complex" do
      assert Value.eqv?({:complex, 1, 2}, {:complex, 1, 2})
      refute Value.eqv?({:complex, 1, 2}, {:complex, 1, 3})
    end

    test "eqv? distinguishes exactness across components" do
      refute Value.eqv?({:complex, 1, 2}, {:complex, 1.0, 2.0})
    end

    test "equal? recurses into components" do
      assert Value.equal?({:complex, 1, 2}, {:complex, 1, 2})
      refute Value.equal?({:complex, 1, 2}, {:complex, 1, 3})
    end
  end
end

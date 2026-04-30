defmodule Schooner.Primitives.InexactTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "exp" do
    test "exp 0 = 1.0" do
      assert run("(exp 0)") == 1.0
    end

    test "exp 1 ≈ e" do
      assert_in_delta run("(exp 1)"), :math.exp(1), 1.0e-12
    end

    test "exp +inf.0 = +inf.0; exp -inf.0 = 0.0" do
      assert run("(exp +inf.0)") == {:float_special, :pos_inf}
      assert run("(exp -inf.0)") == 0.0
    end

    test "exp +nan.0 = +nan.0" do
      assert run("(exp +nan.0)") == {:float_special, :nan}
    end

    test "exp on non-number raises type error" do
      e = assert_raise PError, fn -> run("(exp \"hi\")") end
      assert match?({:type_error, "exp", "number", _}, e.reason)
    end
  end

  describe "log" do
    test "log 1 = 0.0" do
      assert run("(log 1)") == 0.0
    end

    test "log e ≈ 1.0" do
      assert_in_delta run("(log (exp 1))"), 1.0, 1.0e-12
    end

    test "log 0 = -inf.0" do
      assert run("(log 0)") == {:float_special, :neg_inf}
    end

    test "log of positive zero floats = -inf.0" do
      assert run("(log 0.0)") == {:float_special, :neg_inf}
      assert run("(log -0.0)") == {:float_special, :neg_inf}
    end

    test "log on positive float = :math.log" do
      assert_in_delta run("(log 2.5)"), :math.log(2.5), 1.0e-12
    end

    test "log of NaN = NaN; log of +inf = +inf" do
      assert run("(log +nan.0)") == {:float_special, :nan}
      assert run("(log +inf.0)") == {:float_special, :pos_inf}
    end

    test "log of -inf raises (would be complex)" do
      e = assert_raise PError, fn -> run("(log -inf.0)") end
      assert match?({:irrational, "log", _}, e.reason)
    end

    test "log of negative integer lifts to complex" do
      assert run("(log -1)") == {:complex, 0.0, :math.pi()}
    end

    test "log of negative float lifts to complex" do
      assert run("(log -1.5)") == {:complex, :math.log(1.5), :math.pi()}
    end

    test "log on non-number raises type error" do
      e = assert_raise PError, fn -> run(~s{(log "hi")}) end
      assert match?({:type_error, "log", "number", _}, e.reason)
    end

    test "log with base — log base 10 of 1000 ≈ 3.0" do
      assert_in_delta run("(log 1000 10)"), 3.0, 1.0e-12
    end
  end

  describe "sin / cos / tan" do
    test "sin 0 = 0.0; cos 0 = 1.0; tan 0 = 0.0" do
      assert run("(sin 0)") == 0.0
      assert run("(cos 0)") == 1.0
      assert run("(tan 0)") == 0.0
    end

    test "sin pi ≈ 0" do
      assert_in_delta run("(sin (* 4 (atan 1)))"), 0.0, 1.0e-12
    end

    test "cos +nan.0 = +nan.0" do
      assert run("(cos +nan.0)") == {:float_special, :nan}
    end

    test "trig functions raise on non-number arg" do
      e = assert_raise PError, fn -> run(~s{(sin "x")}) end
      assert match?({:type_error, "sin", "number", _}, e.reason)

      e = assert_raise PError, fn -> run(~s{(cos "x")}) end
      assert match?({:type_error, "cos", "number", _}, e.reason)

      e = assert_raise PError, fn -> run(~s{(tan "x")}) end
      assert match?({:type_error, "tan", "number", _}, e.reason)
    end
  end

  describe "asin / acos" do
    test "asin 0 = 0; acos 1 = 0" do
      assert run("(asin 0)") == 0.0
      assert run("(acos 1)") == 0.0
    end

    test "asin/acos on float in range" do
      assert_in_delta run("(asin 0.5)"), :math.asin(0.5), 1.0e-12
      assert_in_delta run("(acos 0.5)"), :math.acos(0.5), 1.0e-12
    end

    test "asin/acos on +nan.0 = +nan.0" do
      assert run("(asin +nan.0)") == {:float_special, :nan}
      assert run("(acos +inf.0)") == {:float_special, :nan}
    end

    test "asin out of [-1,1] lifts into the complex plane" do
      assert run("(asin 2)") == run("(asin (make-rectangular 2 0))")
      assert run("(asin -1.5)") == run("(asin (make-rectangular -1.5 0))")
    end

    test "acos out of [-1,1] lifts into the complex plane" do
      assert run("(acos -2.5)") == run("(acos (make-rectangular -2.5 0))")
      assert run("(acos 2)") == run("(acos (make-rectangular 2 0))")
    end

    test "asin/acos on non-number raises type error" do
      e = assert_raise PError, fn -> run(~s{(asin "hi")}) end
      assert match?({:type_error, "asin", "number", _}, e.reason)

      e = assert_raise PError, fn -> run(~s{(acos "hi")}) end
      assert match?({:type_error, "acos", "number", _}, e.reason)
    end
  end

  describe "atan" do
    test "atan 1 ≈ pi/4" do
      assert_in_delta run("(atan 1)"), :math.pi() / 4.0, 1.0e-12
    end

    test "atan on float = :math.atan" do
      assert_in_delta run("(atan 0.5)"), :math.atan(0.5), 1.0e-12
    end

    test "atan +inf.0 = pi/2; atan -inf.0 = -pi/2" do
      assert_in_delta run("(atan +inf.0)"), :math.pi() / 2.0, 1.0e-12
      assert_in_delta run("(atan -inf.0)"), -:math.pi() / 2.0, 1.0e-12
    end

    test "atan +nan.0 = +nan.0" do
      assert run("(atan +nan.0)") == {:float_special, :nan}
    end

    test "atan on non-number raises type error" do
      e = assert_raise PError, fn -> run(~s{(atan "hi")}) end
      assert match?({:type_error, "atan", "number", _}, e.reason)
    end

    test "two-arg atan = atan2(y, x)" do
      assert_in_delta run("(atan 1 1)"), :math.pi() / 4.0, 1.0e-12
      assert_in_delta run("(atan 0 -1)"), :math.pi(), 1.0e-12
    end

    test "two-arg atan with +nan.0 in either slot = +nan.0" do
      assert run("(atan +nan.0 1)") == {:float_special, :nan}
      assert run("(atan 1 +nan.0)") == {:float_special, :nan}
    end

    test "two-arg atan with non-number raises pointing at the offender" do
      e = assert_raise PError, fn -> run(~s{(atan 1 "x")}) end
      assert match?({:type_error, "atan", "number", _}, e.reason)

      e = assert_raise PError, fn -> run(~s{(atan "x" 1)}) end
      assert match?({:type_error, "atan", "number", _}, e.reason)
    end

    test "atan with too many arguments raises an arity-shaped type error" do
      e = assert_raise PError, fn -> run("(atan 1 2 3)") end
      assert e.reason == {:type_error, "atan", "1 or 2 arguments", :too_many}
    end
  end

  describe "finite? / infinite? / nan?" do
    test "finite?" do
      assert run("(finite? 0)") == Value.bool(true)
      assert run("(finite? 1.5)") == Value.bool(true)
      assert run("(finite? +inf.0)") == Value.bool(false)
      assert run("(finite? -inf.0)") == Value.bool(false)
      assert run("(finite? +nan.0)") == Value.bool(false)
    end

    test "infinite?" do
      assert run("(infinite? 1.5)") == Value.bool(false)
      assert run("(infinite? +inf.0)") == Value.bool(true)
      assert run("(infinite? -inf.0)") == Value.bool(true)
      assert run("(infinite? +nan.0)") == Value.bool(false)
    end

    test "nan?" do
      assert run("(nan? 0)") == Value.bool(false)
      assert run("(nan? +inf.0)") == Value.bool(false)
      assert run("(nan? +nan.0)") == Value.bool(true)
    end

    test "predicates raise on non-number arg" do
      e = assert_raise PError, fn -> run("(finite? \"hi\")") end
      assert match?({:type_error, "finite?", "number", _}, e.reason)

      e = assert_raise PError, fn -> run(~s{(infinite? "hi")}) end
      assert match?({:type_error, "infinite?", "number", _}, e.reason)

      e = assert_raise PError, fn -> run(~s{(nan? "hi")}) end
      assert match?({:type_error, "nan?", "number", _}, e.reason)
    end
  end

  describe "exp on floats" do
    test "exp on float input = :math.exp" do
      assert_in_delta run("(exp 1.5)"), :math.exp(1.5), 1.0e-12
    end
  end

  # ---------------------------------------------------------------------------
  # Rational inputs — every transcendental coerces a rational to its float
  # value and runs through the float path. Pin those branches.
  # ---------------------------------------------------------------------------

  describe "transcendentals on rational inputs" do
    test "exp / log / sin / cos / tan / atan accept rationals" do
      assert_in_delta run("(exp 1/2)"), :math.exp(0.5), 1.0e-12
      assert_in_delta run("(log 1/2)"), :math.log(0.5), 1.0e-12
      assert_in_delta run("(sin 1/2)"), :math.sin(0.5), 1.0e-12
      assert_in_delta run("(cos 1/2)"), :math.cos(0.5), 1.0e-12
      assert_in_delta run("(tan 1/2)"), :math.tan(0.5), 1.0e-12
      assert_in_delta run("(atan 1/2)"), :math.atan(0.5), 1.0e-12
    end

    test "asin / acos accept in-range rationals" do
      assert_in_delta run("(asin 1/2)"), :math.asin(0.5), 1.0e-12
      assert_in_delta run("(acos 1/2)"), :math.acos(0.5), 1.0e-12
    end

    test "log of a negative rational lifts to complex" do
      assert run("(log -1/2)") == {:complex, :math.log(0.5), :math.pi()}
    end
  end

  # ---------------------------------------------------------------------------
  # Complex inputs that bypass the lift-on-out-of-range branch — pin the
  # `is_complex` clauses on asin/acos and the generic_expt path.
  # ---------------------------------------------------------------------------

  describe "transcendentals on direct complex inputs" do
    test "asin / acos on a complex literal go through the complex clause" do
      {:complex, r, i} = run("(asin 0+i)")
      # asin(i) = i * asinh(1)
      assert_in_delta r, 0.0, 1.0e-12
      assert_in_delta i, :math.log(1.0 + :math.sqrt(2.0)), 1.0e-12

      {:complex, r, i} = run("(acos 0+i)")
      assert_in_delta r, :math.pi() / 2.0, 1.0e-12
      assert_in_delta i, -:math.log(1.0 + :math.sqrt(2.0)), 1.0e-12
    end

    test "log of a complex with rational components flows through real_to_float" do
      {:complex, r, i} = run("(log 1/2+1/2i)")
      # |1/2 + 1/2 i| = sqrt(1/2); arg = π/4
      assert_in_delta r, :math.log(:math.sqrt(0.5)), 1.0e-12
      assert_in_delta i, :math.pi() / 4.0, 1.0e-12
    end

    test "two-arg log with a complex operand exits via the complex quotient path" do
      # log_2(1+i) = log(1+i) / log(2)
      {:complex, r, i} = run("(log 1+i 2)")
      ln2 = :math.log(2.0)
      assert_in_delta r, :math.log(:math.sqrt(2.0)) / ln2, 1.0e-12
      assert_in_delta i, :math.pi() / 4.0 / ln2, 1.0e-12
    end

    test "expt with a complex exponent dispatches to generic_expt" do
      # (expt 2 i) = exp(i * log 2) = cos(ln 2) + i sin(ln 2)
      {:complex, r, i} = run("(expt 2 +i)")
      ln2 = :math.log(2.0)
      assert_in_delta r, :math.cos(ln2), 1.0e-12
      assert_in_delta i, :math.sin(ln2), 1.0e-12
    end

    test "expt with both operands complex dispatches to generic_expt" do
      {:complex, r, i} = run("(expt 1+i 1+i)")
      # (1+i)^(1+i) = exp((1+i) * log(1+i))
      # log(1+i) = ln(sqrt 2) + i*π/4
      lr = :math.log(:math.sqrt(2.0))
      li = :math.pi() / 4.0
      # (1+i)*(lr + li i) = (lr - li) + (lr + li)i
      pr = lr - li
      pi_ = lr + li
      ea = :math.exp(pr)
      assert_in_delta r, ea * :math.cos(pi_), 1.0e-12
      assert_in_delta i, ea * :math.sin(pi_), 1.0e-12
    end
  end
end

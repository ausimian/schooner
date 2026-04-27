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

    test "log of negative integer raises" do
      e = assert_raise PError, fn -> run("(log -1)") end
      assert match?({:irrational, "log", _}, e.reason)
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
  end

  describe "asin / acos" do
    test "asin 0 = 0; acos 1 = 0" do
      assert run("(asin 0)") == 0.0
      assert run("(acos 1)") == 0.0
    end

    test "asin out of [-1,1] raises" do
      e = assert_raise PError, fn -> run("(asin 2)") end
      assert match?({:irrational, "asin", _}, e.reason)
    end

    test "acos out of [-1,1] raises" do
      e = assert_raise PError, fn -> run("(acos -2.5)") end
      assert match?({:irrational, "acos", _}, e.reason)
    end
  end

  describe "atan" do
    test "atan 1 ≈ pi/4" do
      assert_in_delta run("(atan 1)"), :math.pi() / 4.0, 1.0e-12
    end

    test "atan +inf.0 = pi/2; atan -inf.0 = -pi/2" do
      assert_in_delta run("(atan +inf.0)"), :math.pi() / 2.0, 1.0e-12
      assert_in_delta run("(atan -inf.0)"), -:math.pi() / 2.0, 1.0e-12
    end

    test "two-arg atan = atan2(y, x)" do
      assert_in_delta run("(atan 1 1)"), :math.pi() / 4.0, 1.0e-12
      assert_in_delta run("(atan 0 -1)"), :math.pi(), 1.0e-12
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
    end
  end
end

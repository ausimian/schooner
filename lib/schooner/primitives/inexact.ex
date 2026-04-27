defmodule Schooner.Primitives.Inexact do
  @moduledoc """
  The `(scheme inexact)` library: transcendental functions
  (`exp`, `log`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`) and the
  non-finite-number predicates `finite?`, `infinite?`, `nan?`.

  Outputs are always inexact (Erlang floats or Schooner's
  `{:float_special, _}` sentinels). Per Schooner's no-rationals /
  no-complex policy, operations whose principal-branch real result
  would step outside the float domain raise
  `Schooner.Primitive.Error` rather than silently widening:

    * `(log x)` for `x < 0` raises (would be complex).
    * `(asin x)` / `(acos x)` for finite `x` outside `[-1, 1]` raise.

  `(log 0)` returns `-inf.0`, matching the IEEE 754 behaviour of
  `:math.log/1` once we recognise zero as a special edge case.
  """

  alias Schooner.Primitive.Error
  alias Schooner.Value

  defguardp is_finite_number(n) when is_integer(n) or is_float(n)
  defguardp is_special(n) when is_tuple(n) and tuple_size(n) == 2 and elem(n, 0) == :float_special

  @doc """
  Return every `(scheme inexact)` primitive as a `{name, arity, fun}`
  tuple. Used by `Schooner.Library.Standard` to assemble
  `(scheme inexact)`.
  """
  @spec specs() :: [{binary(), non_neg_integer() | {:at_least, non_neg_integer()}, fun()}]
  def specs do
    [
      {"exp", 1, &exp_/1},
      {"log", {:at_least, 1}, &log_/1},
      {"sin", 1, &sin_/1},
      {"cos", 1, &cos_/1},
      {"tan", 1, &tan_/1},
      {"asin", 1, &asin_/1},
      {"acos", 1, &acos_/1},
      {"atan", {:at_least, 1}, &atan_/1},
      {"finite?", 1, &finite_p/1},
      {"infinite?", 1, &infinite_p/1},
      {"nan?", 1, &nan_p/1}
    ]
  end

  # ---------------------------------------------------------------------------
  # exp / log
  # ---------------------------------------------------------------------------

  defp exp_([{:float_special, :nan}]), do: {:float_special, :nan}
  defp exp_([{:float_special, :pos_inf}]), do: {:float_special, :pos_inf}
  defp exp_([{:float_special, :neg_inf}]), do: 0.0
  defp exp_([n]) when is_integer(n), do: :math.exp(n * 1.0)
  defp exp_([n]) when is_float(n), do: :math.exp(n)
  defp exp_([other]), do: raise_type("exp", other)

  defp log_([x]), do: log_one(x, "log")
  defp log_([x, b]), do: log_one(x, "log") / log_one(b, "log")

  defp log_one({:float_special, :nan}, _), do: {:float_special, :nan}
  defp log_one({:float_special, :pos_inf}, _), do: {:float_special, :pos_inf}

  defp log_one({:float_special, :neg_inf} = v, name),
    do: raise_irrational(name, v)

  defp log_one(0, _), do: {:float_special, :neg_inf}
  defp log_one(+0.0, _), do: {:float_special, :neg_inf}
  defp log_one(-0.0, _), do: {:float_special, :neg_inf}
  defp log_one(n, _) when is_integer(n) and n > 0, do: :math.log(n * 1.0)
  defp log_one(n, _) when is_float(n) and n > 0.0, do: :math.log(n)
  defp log_one(n, name) when is_integer(n) and n < 0, do: raise_irrational(name, n)
  defp log_one(n, name) when is_float(n) and n < 0.0, do: raise_irrational(name, n)
  defp log_one(other, name), do: raise_type(name, other)

  # ---------------------------------------------------------------------------
  # sin / cos / tan
  # ---------------------------------------------------------------------------

  defp sin_([x]), do: trig_one(x, &:math.sin/1, "sin")
  defp cos_([x]), do: trig_one(x, &:math.cos/1, "cos")
  defp tan_([x]), do: trig_one(x, &:math.tan/1, "tan")

  defp trig_one(special, _f, _name) when is_special(special), do: {:float_special, :nan}
  defp trig_one(n, f, _name) when is_integer(n), do: f.(n * 1.0)
  defp trig_one(n, f, _name) when is_float(n), do: f.(n)
  defp trig_one(other, _f, name), do: raise_type(name, other)

  # ---------------------------------------------------------------------------
  # asin / acos — domain [-1, 1]
  # ---------------------------------------------------------------------------

  defp asin_([x]), do: bounded_inv(x, &:math.asin/1, "asin")
  defp acos_([x]), do: bounded_inv(x, &:math.acos/1, "acos")

  defp bounded_inv(special, _f, _name) when is_special(special), do: {:float_special, :nan}

  defp bounded_inv(n, _f, name) when is_finite_number(n) and (n < -1 or n > 1),
    do: raise_irrational(name, n)

  defp bounded_inv(n, f, _name) when is_integer(n), do: f.(n * 1.0)
  defp bounded_inv(n, f, _name) when is_float(n), do: f.(n)
  defp bounded_inv(other, _f, name), do: raise_type(name, other)

  # ---------------------------------------------------------------------------
  # atan — 1-arg arctan, 2-arg atan2
  # ---------------------------------------------------------------------------

  defp atan_([x]), do: atan_one(x, "atan")
  defp atan_([y, x]), do: atan_two(y, x, "atan")
  defp atan_(_), do: raise(Error, reason: {:type_error, "atan", "1 or 2 arguments", :too_many})

  defp atan_one({:float_special, :pos_inf}, _), do: :math.pi() / 2.0
  defp atan_one({:float_special, :neg_inf}, _), do: -:math.pi() / 2.0
  defp atan_one({:float_special, :nan}, _), do: {:float_special, :nan}
  defp atan_one(n, _) when is_integer(n), do: :math.atan(n * 1.0)
  defp atan_one(n, _) when is_float(n), do: :math.atan(n)
  defp atan_one(other, name), do: raise_type(name, other)

  defp atan_two({:float_special, :nan}, _, _), do: {:float_special, :nan}
  defp atan_two(_, {:float_special, :nan}, _), do: {:float_special, :nan}

  defp atan_two(y, x, _) when is_finite_number(y) and is_finite_number(x),
    do: :math.atan2(y * 1.0, x * 1.0)

  defp atan_two(y, x, name) when is_finite_number(y), do: raise_type(name, x)
  defp atan_two(y, _, name), do: raise_type(name, y)

  # ---------------------------------------------------------------------------
  # finite? / infinite? / nan?
  # ---------------------------------------------------------------------------

  defp finite_p([n]) when is_finite_number(n), do: Value.bool(true)
  defp finite_p([n]) when is_special(n), do: Value.bool(false)
  defp finite_p([other]), do: raise_type("finite?", other)

  defp infinite_p([{:float_special, k}]) when k in [:pos_inf, :neg_inf], do: Value.bool(true)
  defp infinite_p([{:float_special, :nan}]), do: Value.bool(false)
  defp infinite_p([n]) when is_finite_number(n), do: Value.bool(false)
  defp infinite_p([other]), do: raise_type("infinite?", other)

  defp nan_p([{:float_special, :nan}]), do: Value.bool(true)
  defp nan_p([{:float_special, k}]) when k in [:pos_inf, :neg_inf], do: Value.bool(false)
  defp nan_p([n]) when is_finite_number(n), do: Value.bool(false)
  defp nan_p([other]), do: raise_type("nan?", other)

  defp raise_type(op, other), do: raise(Error, reason: {:type_error, op, "number", other})
  defp raise_irrational(op, value), do: raise(Error, reason: {:irrational, op, value})
end

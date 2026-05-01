defmodule Schooner.Primitives.Inexact do
  @moduledoc """
  The `(scheme inexact)` library: transcendental functions
  (`exp`, `log`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`) and the
  non-finite-number predicates `finite?`, `infinite?`, `nan?`.

  Real outputs are inexact (Erlang floats or `{:float_special, _}`).
  Inputs that would step off the real line lift into the complex tower
  on the principal branch:

    * `(log x)` for negative real `x` returns `log|x| + iπ`.
    * `exp`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, and `log`
      accept complex arguments and return complex.

  Real `(asin x)` / `(acos x)` outside `[-1, 1]` still raise rather
  than lifting silently — pass `(make-rectangular x 0)` to opt in.
  `(log 0)` returns `-inf.0`, matching `:math.log/1` once we recognise
  zero as a special edge case.
  """

  alias Schooner.Primitive.Error
  alias Schooner.Value

  defguardp is_finite_number(n) when is_integer(n) or is_float(n)
  defguardp is_special(n) when is_tuple(n) and tuple_size(n) == 2 and elem(n, 0) == :float_special
  defguardp is_rational(v) when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :rational
  defguardp is_complex(v) when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :complex

  @doc """
  Return every `(scheme inexact)` primitive as a `{name, arity, fun}`
  tuple. Used by `Schooner.Library.Standard` to assemble
  `(scheme inexact)`.
  """
  @spec specs() :: [{binary(), Value.arity_spec(), fun()}]
  def specs do
    [
      {"exp", 1, &exp_/1},
      {"log", {:between, 1, 2}, &log_/1},
      {"sin", 1, &sin_/1},
      {"cos", 1, &cos_/1},
      {"tan", 1, &tan_/1},
      {"asin", 1, &asin_/1},
      {"acos", 1, &acos_/1},
      {"atan", {:between, 1, 2}, &atan_/1},
      {"finite?", 1, &finite_p/1},
      {"infinite?", 1, &infinite_p/1},
      {"nan?", 1, &nan_p/1}
    ]
  end

  # ---------------------------------------------------------------------------
  # exp / log
  # ---------------------------------------------------------------------------

  defp exp_([z]) when is_complex(z), do: complex_exp(z)
  defp exp_([{:float_special, :nan}]), do: {:float_special, :nan}
  defp exp_([{:float_special, :pos_inf}]), do: {:float_special, :pos_inf}
  defp exp_([{:float_special, :neg_inf}]), do: 0.0
  defp exp_([n]) when is_integer(n), do: :math.exp(n * 1.0)
  defp exp_([n]) when is_float(n), do: :math.exp(n)
  defp exp_([n]) when is_rational(n), do: :math.exp(real_to_float(n))
  defp exp_([other]), do: raise_type("exp", other)

  defp log_([x]), do: log_one(x, "log")
  defp log_([x, b]), do: log_quotient(x, b)

  # Two-arg `log` lifts to complex when either operand asks for it.
  # Both halves compute as complex logs; the quotient reuses the
  # rectangular `div_pair` on float components.
  defp log_quotient(x, b) when is_complex(x) or is_complex(b) do
    div_pair(log_pair(complex_floats(x)), log_pair(complex_floats(b)))
    |> finish()
  end

  defp log_quotient(x, b), do: log_one(x, "log") / log_one(b, "log")

  defp complex_floats({:complex, r, i}), do: {real_to_float(r), real_to_float(i)}
  defp complex_floats(n), do: {real_to_float(n), 0.0}

  defp real_to_float(n) when is_integer(n), do: n * 1.0
  defp real_to_float(n) when is_float(n), do: n
  defp real_to_float({:rational, n, d}), do: n / d

  defp log_one(z, _) when is_complex(z), do: complex_log(z)
  defp log_one({:float_special, :nan}, _), do: {:float_special, :nan}
  defp log_one({:float_special, :pos_inf}, _), do: {:float_special, :pos_inf}

  defp log_one({:float_special, :neg_inf} = v, name),
    do: raise_irrational(name, v)

  defp log_one(0, _), do: {:float_special, :neg_inf}
  defp log_one(+0.0, _), do: {:float_special, :neg_inf}
  defp log_one(-0.0, _), do: {:float_special, :neg_inf}
  defp log_one(n, _) when is_integer(n) and n > 0, do: :math.log(n * 1.0)
  defp log_one(n, _) when is_float(n) and n > 0.0, do: :math.log(n)
  defp log_one(n, _) when is_rational(n), do: log_rational(n)

  defp log_one(n, name) when is_integer(n) and n < 0,
    do: complex_log_negative(n, name)

  defp log_one(n, name) when is_float(n) and n < 0.0,
    do: complex_log_negative(n, name)

  defp log_one(other, name), do: raise_type(name, other)

  defp log_rational({:rational, n, d}) when n > 0, do: :math.log(n / d)
  defp log_rational(r), do: complex_log_negative(r, "log")

  # Real negative inputs lift into the imaginary axis: log(-x) = log(x) + iπ.
  defp complex_log_negative(n, _name) do
    f = real_to_float(n)
    Value.complex(:math.log(:math.sqrt(f * f)), :math.pi())
  end

  # ---------------------------------------------------------------------------
  # sin / cos / tan
  # ---------------------------------------------------------------------------

  defp sin_([x]), do: trig_one(x, &:math.sin/1, &complex_sin/1, "sin")
  defp cos_([x]), do: trig_one(x, &:math.cos/1, &complex_cos/1, "cos")
  defp tan_([x]), do: trig_one(x, &:math.tan/1, &complex_tan/1, "tan")

  defp trig_one(z, _f, fc, _name) when is_complex(z), do: fc.(z)
  defp trig_one(special, _f, _fc, _name) when is_special(special), do: {:float_special, :nan}
  defp trig_one(n, f, _fc, _name) when is_integer(n), do: f.(n * 1.0)
  defp trig_one(n, f, _fc, _name) when is_float(n), do: f.(n)
  defp trig_one(n, f, _fc, _name) when is_rational(n), do: f.(real_to_float(n))
  defp trig_one(other, _f, _fc, name), do: raise_type(name, other)

  # ---------------------------------------------------------------------------
  # asin / acos — domain [-1, 1]
  # ---------------------------------------------------------------------------

  defp asin_([x]), do: bounded_inv(x, &:math.asin/1, &complex_asin/1, "asin")
  defp acos_([x]), do: bounded_inv(x, &:math.acos/1, &complex_acos/1, "acos")

  defp bounded_inv(z, _f, fc, _name) when is_complex(z), do: fc.(z)
  defp bounded_inv(special, _f, _fc, _name) when is_special(special), do: {:float_special, :nan}

  defp bounded_inv(n, _f, fc, _name) when is_finite_number(n) and (n < -1 or n > 1),
    do: fc.(Value.complex(n, 0))

  defp bounded_inv(n, f, _fc, _name) when is_integer(n), do: f.(n * 1.0)
  defp bounded_inv(n, f, _fc, _name) when is_float(n), do: f.(n)
  defp bounded_inv(n, f, _fc, _name) when is_rational(n), do: f.(real_to_float(n))
  defp bounded_inv(other, _f, _fc, name), do: raise_type(name, other)

  # ---------------------------------------------------------------------------
  # atan — 1-arg arctan, 2-arg atan2
  # ---------------------------------------------------------------------------

  defp atan_([x]), do: atan_one(x, "atan")
  defp atan_([y, x]), do: atan_two(y, x, "atan")

  defp atan_one(z, _) when is_complex(z), do: complex_atan(z)
  defp atan_one({:float_special, :pos_inf}, _), do: :math.pi() / 2.0
  defp atan_one({:float_special, :neg_inf}, _), do: -:math.pi() / 2.0
  defp atan_one({:float_special, :nan}, _), do: {:float_special, :nan}
  defp atan_one(n, _) when is_integer(n), do: :math.atan(n * 1.0)
  defp atan_one(n, _) when is_float(n), do: :math.atan(n)
  defp atan_one(n, _) when is_rational(n), do: :math.atan(real_to_float(n))
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

  # ---------------------------------------------------------------------------
  # Complex transcendentals
  # ---------------------------------------------------------------------------
  #
  # Internal complex values flow as raw `{re, im}` float pairs; the
  # public `complex_*` entry points wrap and unwrap so external callers
  # only ever see Schooner values. All outputs are inexact — these
  # routines drop any exact rational structure of their inputs because
  # the underlying transcendentals are inherently inexact.

  @doc """
  `expt(z, w) = exp(w * log z)` on the complex tower. Public so the
  base-library `expt` primitive can defer the non-integer-exponent
  path here without exposing the underlying complex `exp` / `log`.
  """
  @spec generic_expt(Value.complex_v() | Value.real_v(), Value.complex_v() | Value.real_v()) ::
          Value.t()
  def generic_expt(base, exp) do
    log_z = complex_floats(base) |> log_pair()
    {wr, wi} = complex_floats(exp)
    {lr, li} = log_z
    product = {wr * lr - wi * li, wr * li + wi * lr}
    finish(exp_pair(product))
  end

  defp complex_exp(z), do: exp_pair(complex_floats(z)) |> finish()
  defp complex_log(z), do: log_pair(complex_floats(z)) |> finish()
  defp complex_sin(z), do: sin_pair(complex_floats(z)) |> finish()
  defp complex_cos(z), do: cos_pair(complex_floats(z)) |> finish()
  defp complex_tan(z), do: tan_pair(complex_floats(z)) |> finish()
  defp complex_asin(z), do: asin_pair(complex_floats(z)) |> finish()
  defp complex_acos(z), do: acos_pair(complex_floats(z)) |> finish()
  defp complex_atan(z), do: atan_pair(complex_floats(z)) |> finish()

  defp finish({re, im}), do: Value.complex(re, im)

  defp exp_pair({a, b}) do
    ea = :math.exp(a)
    {ea * :math.cos(b), ea * :math.sin(b)}
  end

  defp log_pair({a, b}),
    do: {:math.log(:math.sqrt(a * a + b * b)), :math.atan2(b, a)}

  # sin(a+bi) = sin a cosh b + i cos a sinh b
  defp sin_pair({a, b}),
    do: {:math.sin(a) * :math.cosh(b), :math.cos(a) * :math.sinh(b)}

  # cos(a+bi) = cos a cosh b - i sin a sinh b
  defp cos_pair({a, b}),
    do: {:math.cos(a) * :math.cosh(b), -:math.sin(a) * :math.sinh(b)}

  # tan(z) = sin z / cos z
  defp tan_pair(p), do: div_pair(sin_pair(p), cos_pair(p))

  # asin(z) = -i * log(iz + sqrt(1 - z^2))
  defp asin_pair(p) do
    one_minus_z2 = sub_pair({1.0, 0.0}, square_pair(p))
    inner = add_pair(mul_i_pair(p), sqrt_pair(one_minus_z2))
    mul_neg_i_pair(log_pair(inner))
  end

  # acos(z) = π/2 - asin(z)
  defp acos_pair(p) do
    {ar, ai} = asin_pair(p)
    {:math.pi() / 2.0 - ar, -ai}
  end

  # atan(z) = (i/2) * (log(1 - iz) - log(1 + iz))
  defp atan_pair(p) do
    iz = mul_i_pair(p)
    {dr, di} = sub_pair(log_pair(sub_pair({1.0, 0.0}, iz)), log_pair(add_pair({1.0, 0.0}, iz)))
    # multiply by i/2: (dr + di*i) * (i/2) = -di/2 + (dr/2)i
    {-di / 2.0, dr / 2.0}
  end

  defp add_pair({ar, ai}, {br, bi}), do: {ar + br, ai + bi}
  defp sub_pair({ar, ai}, {br, bi}), do: {ar - br, ai - bi}

  defp div_pair({ar, ai}, {br, bi}) do
    denom = br * br + bi * bi
    {(ar * br + ai * bi) / denom, (ai * br - ar * bi) / denom}
  end

  defp square_pair({a, b}), do: {a * a - b * b, 2.0 * a * b}

  defp sqrt_pair({a, b}) do
    m = :math.sqrt(a * a + b * b)
    re = :math.sqrt((m + a) / 2.0)
    im_mag = :math.sqrt(max((m - a) / 2.0, 0.0))
    {re, if(b < 0.0, do: -im_mag, else: im_mag)}
  end

  defp mul_i_pair({a, b}), do: {-b, a}
  defp mul_neg_i_pair({a, b}), do: {b, -a}
end

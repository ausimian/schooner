defmodule Schooner.Primitives.Base do
  @moduledoc """
  Numeric core, type predicates, and boolean helpers from `(scheme base)`.

  Every binding here is registered as a `Schooner.Value.primitive/3` value
  in the standard environment. The evaluator already understands those
  via `Schooner.Eval.apply_proc/2` — this module just supplies the
  Elixir-side implementations.

  Exactness rules follow r7rs: exact inputs (integers and rationals)
  produce exact results where possible; any inexact (float) operand
  contaminates the whole expression. Operations that would step outside
  the rational tower — complex numbers, irrationals — raise
  `Schooner.Primitive.Error` rather than silently widening, since
  Schooner ships only the integer/rational/real layers.
  """

  alias Schooner.Eval
  alias Schooner.Primitive.Error
  alias Schooner.Primitives.Inexact
  alias Schooner.Value

  defguardp is_special(v)
            when is_tuple(v) and tuple_size(v) == 2 and elem(v, 0) == :float_special

  defguardp is_rational(v)
            when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :rational

  defguardp is_complex(v)
            when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :complex

  defguardp is_exact(v) when is_integer(v) or is_rational(v)

  defguardp is_real_v(v) when is_integer(v) or is_float(v) or is_rational(v) or is_special(v)

  # ---------------------------------------------------------------------------
  # Public spec
  # ---------------------------------------------------------------------------

  @doc """
  Return every base-library primitive as a `{name, arity, fun}` tuple.
  `Schooner.Library.Standard` consumes this to assemble the
  `(scheme base)` library entry.
  """
  @spec specs() :: [{binary(), non_neg_integer() | {:at_least, non_neg_integer()}, fun()}]
  def specs do
    arithmetic_specs() ++
      comparison_specs() ++
      predicate_specs() ++
      boolean_specs() ++
      pair_specs() ++
      vector_specs() ++
      bytevector_specs() ++
      string_specs() ++
      symbol_specs() ++
      multi_value_specs()
  end

  # ---------------------------------------------------------------------------
  # Arithmetic
  # ---------------------------------------------------------------------------

  defp arithmetic_specs do
    [
      {"+", {:at_least, 0}, &add/1},
      {"-", {:at_least, 1}, &sub/1},
      {"*", {:at_least, 0}, &mul/1},
      {"/", {:at_least, 1}, &divide/1},
      {"quotient", 2, &quotient/1},
      {"remainder", 2, &remainder/1},
      {"modulo", 2, &modulo/1},
      {"abs", 1, &abs_/1},
      {"min", {:at_least, 1}, &min_/1},
      {"max", {:at_least, 1}, &max_/1},
      {"expt", 2, &expt/1},
      {"gcd", {:at_least, 0}, &gcd_/1},
      {"lcm", {:at_least, 0}, &lcm_/1},
      {"sqrt", 1, &sqrt_/1},
      {"exact->inexact", 1, &exact_to_inexact/1},
      {"inexact->exact", 1, &inexact_to_exact/1},
      {"inexact", 1, &inexact_/1},
      {"exact", 1, &exact_/1},
      {"numerator", 1, &numerator_/1},
      {"denominator", 1, &denominator_/1},
      {"rationalize", 2, &rationalize_/1}
    ]
  end

  defp add([]), do: 0
  defp add(args), do: reduce_numeric("+", args, 0, &add_pair/2)

  defp sub([n]) do
    require_number!("-", n)
    negate(n)
  end

  defp sub([first | rest]) do
    require_number!("-", first)
    reduce_numeric("-", rest, first, &sub_pair/2)
  end

  defp mul([]), do: 1
  defp mul(args), do: reduce_numeric("*", args, 1, &mul_pair/2)

  defp divide([n]) do
    require_number!("/", n)
    divide_pair("/", 1, n)
  end

  defp divide([first | rest]) do
    require_number!("/", first)

    Enum.reduce(rest, first, fn b, a ->
      require_number!("/", b)
      divide_pair("/", a, b)
    end)
  end

  # ---- Specials-aware pairwise arithmetic ------------------------------------

  defp add_pair(a, b) when is_complex(a) or is_complex(b), do: complex_add(a, b)
  defp add_pair(a, b) when is_special(a) or is_special(b), do: special_add(a, b)
  defp add_pair(a, b) when is_float(a) or is_float(b), do: to_float(a) + to_float(b)
  defp add_pair(a, b) when is_rational(a) or is_rational(b), do: rat_add(a, b)
  defp add_pair(a, b), do: a + b

  defp sub_pair(a, b) when is_complex(a) or is_complex(b), do: complex_add(a, negate(b))
  defp sub_pair(a, b) when is_special(a) or is_special(b), do: special_add(a, negate(b))
  defp sub_pair(a, b) when is_float(a) or is_float(b), do: to_float(a) - to_float(b)
  defp sub_pair(a, b) when is_rational(a) or is_rational(b), do: rat_add(a, negate(b))
  defp sub_pair(a, b), do: a - b

  defp mul_pair(a, b) when is_complex(a) or is_complex(b), do: complex_mul(a, b)
  defp mul_pair(a, b) when is_special(a) or is_special(b), do: special_mul(a, b)
  defp mul_pair(a, b) when is_float(a) or is_float(b), do: to_float(a) * to_float(b)
  defp mul_pair(a, b) when is_rational(a) or is_rational(b), do: rat_mul(a, b)
  defp mul_pair(a, b), do: a * b

  defp negate({:float_special, :pos_inf}), do: {:float_special, :neg_inf}
  defp negate({:float_special, :neg_inf}), do: {:float_special, :pos_inf}
  defp negate({:float_special, :nan}), do: {:float_special, :nan}
  defp negate({:rational, n, d}), do: {:rational, -n, d}
  defp negate({:complex, r, i}), do: Value.complex(negate(r), negate(i))
  defp negate(n), do: -n

  # ---- Complex arithmetic ----------------------------------------------------
  #
  # Real operands lift to `{r, 0}` when paired with a complex via
  # `complex_pair/1`; the result is reduced through `Value.complex/2`
  # so real-valued outputs collapse back out of the complex tag (the
  # split is total — no value is both real and complex).

  defp complex_add(a, b) do
    {ar, ai} = complex_pair(a)
    {br, bi} = complex_pair(b)
    Value.complex(add_pair(ar, br), add_pair(ai, bi))
  end

  defp complex_mul(a, b) do
    {ar, ai} = complex_pair(a)
    {br, bi} = complex_pair(b)
    real = sub_pair(mul_pair(ar, br), mul_pair(ai, bi))
    imag = add_pair(mul_pair(ar, bi), mul_pair(ai, br))
    Value.complex(real, imag)
  end

  # (a+bi) / (c+di) = ((ac+bd) + (bc-ad)i) / (c^2 + d^2). Division by
  # an exact zero complex (`0+0i`) is impossible — `0+0i` collapses to
  # `0` on construction, so the divisor here always has a non-zero
  # rectangular norm.
  defp complex_div(a, b) do
    {ar, ai} = complex_pair(a)
    {br, bi} = complex_pair(b)
    denom = add_pair(mul_pair(br, br), mul_pair(bi, bi))

    if denom === 0 do
      raise(Error, reason: {:division_by_zero, "/"})
    end

    real = divide_pair("/", add_pair(mul_pair(ar, br), mul_pair(ai, bi)), denom)
    imag = divide_pair("/", sub_pair(mul_pair(ai, br), mul_pair(ar, bi)), denom)
    Value.complex(real, imag)
  end

  defp complex_pair({:complex, r, i}), do: {r, i}
  defp complex_pair(r) when is_real_v(r), do: {r, 0}

  # Exact rational arithmetic. Inputs may be integers or `{:rational, n, d}`;
  # Value.rational/2 normalises and collapses denom-1 results back to a bare
  # integer, keeping the integer/rational split total.
  defp rat_add(a, b) do
    {n1, d1} = rat_pair(a)
    {n2, d2} = rat_pair(b)
    Value.rational(n1 * d2 + n2 * d1, d1 * d2)
  end

  defp rat_mul(a, b) do
    {n1, d1} = rat_pair(a)
    {n2, d2} = rat_pair(b)
    Value.rational(n1 * n2, d1 * d2)
  end

  defp rat_div(a, b) do
    {n1, d1} = rat_pair(a)
    {n2, d2} = rat_pair(b)
    if n2 == 0, do: raise(Error, reason: {:division_by_zero, "/"})
    Value.rational(n1 * d2, d1 * n2)
  end

  defp rat_pair({:rational, n, d}), do: {n, d}
  defp rat_pair(n) when is_integer(n), do: {n, 1}

  # NaN propagates; otherwise IEEE-754 inf rules. `+inf + -inf` → NaN.
  defp special_add({:float_special, :nan}, _), do: {:float_special, :nan}
  defp special_add(_, {:float_special, :nan}), do: {:float_special, :nan}

  defp special_add({:float_special, :pos_inf}, {:float_special, :neg_inf}),
    do: {:float_special, :nan}

  defp special_add({:float_special, :neg_inf}, {:float_special, :pos_inf}),
    do: {:float_special, :nan}

  defp special_add({:float_special, k}, {:float_special, k}), do: {:float_special, k}
  defp special_add({:float_special, k}, _finite), do: {:float_special, k}
  defp special_add(_finite, {:float_special, k}), do: {:float_special, k}

  # NaN propagates; inf*inf rules; inf*0 (any zero) is NaN.
  defp special_mul({:float_special, :nan}, _), do: {:float_special, :nan}
  defp special_mul(_, {:float_special, :nan}), do: {:float_special, :nan}

  defp special_mul({:float_special, ka}, {:float_special, kb}) do
    if ka == kb, do: {:float_special, :pos_inf}, else: {:float_special, :neg_inf}
  end

  defp special_mul({:float_special, k}, finite), do: scale_inf(k, sign_finite(finite))
  defp special_mul(finite, {:float_special, k}), do: scale_inf(k, sign_finite(finite))

  # Sign of a finite real, treating both +0.0 and -0.0 as zero (their
  # signed-ness only matters for division, not multiplication).
  defp sign_finite(0), do: 0
  defp sign_finite(+0.0), do: 0
  defp sign_finite(-0.0), do: 0
  defp sign_finite(n) when n > 0, do: 1
  defp sign_finite(_), do: -1

  defp scale_inf(_k, 0), do: {:float_special, :nan}
  defp scale_inf(k, 1), do: {:float_special, k}
  defp scale_inf(:pos_inf, -1), do: {:float_special, :neg_inf}
  defp scale_inf(:neg_inf, -1), do: {:float_special, :pos_inf}

  # ---- Division --------------------------------------------------------------

  defp divide_pair(_op, a, b) when is_complex(a) or is_complex(b), do: complex_div(a, b)

  defp divide_pair(_op, a, b) when is_special(a) or is_special(b),
    do: special_divide(a, b)

  defp divide_pair(_op, a, b) when is_float(a) or is_float(b),
    do: do_float_divide(to_float(a), to_float(b))

  # Integer-only fast path keeps `(/ 6 3)` from paying the gcd cost of
  # `Value.rational/2` for the common evenly-divisible case.
  defp divide_pair(_op, a, b) when is_integer(a) and is_integer(b) do
    cond do
      b == 0 -> raise(Error, reason: {:division_by_zero, "/"})
      rem(a, b) == 0 -> div(a, b)
      true -> Value.rational(a, b)
    end
  end

  defp divide_pair(_op, a, b) when is_exact(a) and is_exact(b), do: rat_div(a, b)

  # NaN propagates; inf/inf is NaN; finite/inf is 0; inf/finite preserves
  # sign of inf scaled by sign of divisor.
  defp special_divide({:float_special, :nan}, _), do: {:float_special, :nan}
  defp special_divide(_, {:float_special, :nan}), do: {:float_special, :nan}
  defp special_divide({:float_special, _}, {:float_special, _}), do: {:float_special, :nan}
  defp special_divide(_finite, {:float_special, _}), do: 0.0
  defp special_divide({:float_special, k}, finite), do: scale_inf(k, sign_finite(finite))

  # IEEE-754 finite/zero: sign(numerator) determines the resulting infinity;
  # zero/zero → NaN; sign of the zero divisor flips the result.
  defp do_float_divide(+0.0, +0.0), do: {:float_special, :nan}
  defp do_float_divide(+0.0, -0.0), do: {:float_special, :nan}
  defp do_float_divide(-0.0, +0.0), do: {:float_special, :nan}
  defp do_float_divide(-0.0, -0.0), do: {:float_special, :nan}

  defp do_float_divide(a, +0.0) when a > 0, do: {:float_special, :pos_inf}
  defp do_float_divide(a, +0.0) when a < 0, do: {:float_special, :neg_inf}
  defp do_float_divide(a, -0.0) when a > 0, do: {:float_special, :neg_inf}
  defp do_float_divide(a, -0.0) when a < 0, do: {:float_special, :pos_inf}

  defp do_float_divide(a, b), do: a / b

  defp quotient([a, b]) do
    require_integer!("quotient", a)
    require_integer!("quotient", b)
    if b == 0, do: raise(Error, reason: {:division_by_zero, "quotient"})
    coerce_int_result(a, b, div(trunc_int(a), trunc_int(b)))
  end

  defp remainder([a, b]) do
    require_integer!("remainder", a)
    require_integer!("remainder", b)
    if b == 0, do: raise(Error, reason: {:division_by_zero, "remainder"})
    coerce_int_result(a, b, rem(trunc_int(a), trunc_int(b)))
  end

  defp modulo([a, b]) do
    require_integer!("modulo", a)
    require_integer!("modulo", b)
    if b == 0, do: raise(Error, reason: {:division_by_zero, "modulo"})

    ai = trunc_int(a)
    bi = trunc_int(b)
    r = rem(ai, bi)
    result = if r != 0 and signum(r) != signum(bi), do: r + bi, else: r
    coerce_int_result(a, b, result)
  end

  defp abs_([n]) do
    require_real!("abs", n)
    abs_special(n)
  end

  defp abs_special({:float_special, :neg_inf}), do: {:float_special, :pos_inf}
  defp abs_special({:float_special, k}), do: {:float_special, k}
  defp abs_special({:rational, n, d}), do: {:rational, abs(n), d}
  defp abs_special(n), do: abs(n)

  defp min_([first | rest]) do
    require_real!("min", first)

    Enum.reduce(rest, first, fn b, a ->
      require_real!("min", b)
      pick_min(a, b)
    end)
  end

  defp max_([first | rest]) do
    require_real!("max", first)

    Enum.reduce(rest, first, fn b, a ->
      require_real!("max", b)
      pick_max(a, b)
    end)
  end

  # min/max contaminate exactness even when the chosen value is exact.
  # NaN propagates per r7rs; +inf wins max / -inf wins min.
  defp pick_min({:float_special, :nan}, _), do: {:float_special, :nan}
  defp pick_min(_, {:float_special, :nan}), do: {:float_special, :nan}
  defp pick_min({:float_special, :neg_inf}, _), do: {:float_special, :neg_inf}
  defp pick_min(_, {:float_special, :neg_inf}), do: {:float_special, :neg_inf}
  defp pick_min({:float_special, :pos_inf}, b), do: to_float(b)
  defp pick_min(a, {:float_special, :pos_inf}), do: to_float(a)
  defp pick_min(a, b) when is_float(a) or is_float(b), do: min(to_float(a), to_float(b))
  defp pick_min(a, b), do: if(rat_lt(a, b), do: a, else: b)

  defp pick_max({:float_special, :nan}, _), do: {:float_special, :nan}
  defp pick_max(_, {:float_special, :nan}), do: {:float_special, :nan}
  defp pick_max({:float_special, :pos_inf}, _), do: {:float_special, :pos_inf}
  defp pick_max(_, {:float_special, :pos_inf}), do: {:float_special, :pos_inf}
  defp pick_max({:float_special, :neg_inf}, b), do: to_float(b)
  defp pick_max(a, {:float_special, :neg_inf}), do: to_float(a)
  defp pick_max(a, b) when is_float(a) or is_float(b), do: max(to_float(a), to_float(b))
  defp pick_max(a, b), do: if(rat_lt(a, b), do: b, else: a)

  defp expt([base, exp]) do
    require_number!("expt", base)
    require_number!("expt", exp)
    do_expt(base, exp)
  end

  defp do_expt(base, exp) when is_exact(base) and is_integer(exp) and exp >= 0 do
    rat_int_pow(base, exp)
  end

  defp do_expt(0, exp) when is_integer(exp) and exp < 0,
    do: raise(Error, reason: {:division_by_zero, "expt"})

  defp do_expt(base, exp) when is_exact(base) and is_integer(exp),
    do: rat_div(1, rat_int_pow(base, -exp))

  # Integer exponent on a complex base: repeated multiplication so the
  # result is exact whenever the components are. `(expt (1+i) 2)` ⟹ `2i`.
  defp do_expt(base, exp) when is_complex(base) and is_integer(exp) and exp >= 0,
    do: complex_int_pow(base, exp)

  defp do_expt(base, exp) when is_complex(base) and is_integer(exp) and exp < 0,
    do: complex_div(1, complex_int_pow(base, -exp))

  defp do_expt(base, exp) when is_complex(base) or is_complex(exp),
    do: Inexact.generic_expt(base, exp)

  defp do_expt(base, exp) when is_special(base) or is_special(exp),
    do: special_expt(base, exp)

  defp do_expt(base, exp), do: :math.pow(to_float(base), to_float(exp))

  defp complex_int_pow(_b, 0), do: 1
  defp complex_int_pow(b, 1), do: b

  defp complex_int_pow(b, e) when rem(e, 2) == 0 do
    half = complex_int_pow(b, div(e, 2))
    complex_mul(half, half)
  end

  defp complex_int_pow(b, e), do: complex_mul(b, complex_int_pow(b, e - 1))

  # IEEE-754 pow: anything^0 is 1.0 (even NaN, even infinities); 1^anything
  # is 1.0; NaN otherwise propagates. inf^positive → inf, inf^negative → 0.0,
  # |b|>1 ^ +inf → inf, |b|<1 ^ +inf → 0.0, mirrored for -inf exponents.
  defp special_expt(_, 0), do: 1.0
  defp special_expt(_, +0.0), do: 1.0
  defp special_expt(_, -0.0), do: 1.0
  defp special_expt(1, _), do: 1.0
  defp special_expt(1.0, _), do: 1.0
  defp special_expt({:float_special, :nan}, _), do: {:float_special, :nan}
  defp special_expt(_, {:float_special, :nan}), do: {:float_special, :nan}

  defp special_expt({:float_special, :pos_inf}, exp) do
    case finite_exp_sign(exp) do
      1 -> {:float_special, :pos_inf}
      -1 -> 0.0
      _ -> {:float_special, :nan}
    end
  end

  defp special_expt({:float_special, :neg_inf}, exp) do
    # IEEE-754 pow(-inf, n): odd integer n preserves the sign;
    # even integer n or non-integer n yields the positive form.
    case finite_exp_sign(exp) do
      1 -> if odd_integer?(exp), do: {:float_special, :neg_inf}, else: {:float_special, :pos_inf}
      -1 -> 0.0
      _ -> {:float_special, :nan}
    end
  end

  defp special_expt(base, {:float_special, :pos_inf}) do
    cond do
      is_special(base) -> {:float_special, :pos_inf}
      abs(to_float(base)) > 1.0 -> {:float_special, :pos_inf}
      abs(to_float(base)) < 1.0 -> 0.0
      true -> {:float_special, :nan}
    end
  end

  defp special_expt(base, {:float_special, :neg_inf}) do
    cond do
      is_special(base) -> 0.0
      abs(to_float(base)) > 1.0 -> 0.0
      abs(to_float(base)) < 1.0 -> {:float_special, :pos_inf}
      true -> {:float_special, :nan}
    end
  end

  defp finite_exp_sign(e) when is_integer(e) and e > 0, do: 1
  defp finite_exp_sign(e) when is_integer(e) and e < 0, do: -1
  defp finite_exp_sign(e) when is_float(e) and e > 0.0, do: 1
  defp finite_exp_sign(e) when is_float(e) and e < 0.0, do: -1
  defp finite_exp_sign(_), do: 0

  defp odd_integer?(e) when is_integer(e), do: rem(e, 2) != 0
  defp odd_integer?(e) when is_float(e), do: e == trunc(e) and rem(trunc(e), 2) != 0
  defp odd_integer?(_), do: false

  defp rat_int_pow(_b, 0), do: 1
  defp rat_int_pow(b, 1), do: b

  defp rat_int_pow(b, e) when rem(e, 2) == 0 do
    half = rat_int_pow(b, div(e, 2))
    rat_mul(half, half)
  end

  defp rat_int_pow(b, e), do: rat_mul(b, rat_int_pow(b, e - 1))

  defp gcd_([]), do: 0

  defp gcd_(args) do
    Enum.each(args, &require_integer!("gcd", &1))
    {ints, any_float?} = collect_int_args(args)
    result = Enum.reduce(ints, 0, &Integer.gcd(abs(&1), abs(&2)))
    if any_float?, do: result * 1.0, else: result
  end

  defp lcm_([]), do: 1

  defp lcm_(args) do
    Enum.each(args, &require_integer!("lcm", &1))
    {ints, any_float?} = collect_int_args(args)

    result =
      Enum.reduce(ints, 1, fn x, acc ->
        x = abs(x)
        if x == 0 or acc == 0, do: 0, else: div(acc * x, Integer.gcd(acc, x))
      end)

    if any_float?, do: result * 1.0, else: result
  end

  defp sqrt_([n]) do
    require_number!("sqrt", n)
    do_sqrt(n)
  end

  defp do_sqrt({:float_special, :pos_inf}), do: {:float_special, :pos_inf}
  defp do_sqrt({:float_special, _}), do: {:float_special, :nan}
  defp do_sqrt(n) when is_float(n) and n < 0.0, do: complex_sqrt_real(n)
  defp do_sqrt(n) when is_float(n), do: :math.sqrt(n)
  defp do_sqrt(n) when is_integer(n) and n >= 0, do: exact_isqrt_or_widen(n)
  defp do_sqrt(n) when is_integer(n), do: complex_sqrt_real(n)
  defp do_sqrt({:rational, n, _} = r) when n >= 0, do: rational_sqrt_or_widen(r)
  defp do_sqrt({:rational, _, _} = r), do: complex_sqrt_real(r)
  defp do_sqrt({:complex, _, _} = z), do: complex_sqrt(z)
  defp do_sqrt(n), do: raise(Error, reason: {:irrational, "sqrt", n})

  # `sqrt` of a negative real lifts into the imaginary axis with an
  # inexact imaginary component (`:math.sqrt/1` returns a float).
  defp complex_sqrt_real(n) do
    Value.complex(0, :math.sqrt(-to_float(n)))
  end

  # Principal complex square root via the half-angle formula:
  #   sqrt(z) = sqrt((|z|+a)/2) + sign(b) * sqrt((|z|-a)/2) * i
  # for z = a + bi. Numerically stable for any rectangular complex.
  defp complex_sqrt({:complex, r, i}) do
    a = to_float(r)
    b = to_float(i)
    m = :math.sqrt(a * a + b * b)
    re = :math.sqrt((m + a) / 2.0)
    im_mag = :math.sqrt(max((m - a) / 2.0, 0.0))
    im = if b < 0.0, do: -im_mag, else: im_mag
    Value.complex(re, im)
  end

  defp exact_isqrt_or_widen(n) do
    r = isqrt(n)
    if r * r == n, do: r, else: :math.sqrt(to_float(n))
  end

  defp rational_sqrt_or_widen({:rational, n, d} = r) when n >= 0 do
    sn = isqrt(n)
    sd = isqrt(d)

    if sn * sn == n and sd * sd == d,
      do: Value.rational(sn, sd),
      else: :math.sqrt(to_float(r))
  end

  # Integer square root via Newton's method on arbitrary-precision integers.
  defp isqrt(0), do: 0

  defp isqrt(n) when n > 0 do
    isqrt_loop(n, n)
  end

  defp isqrt_loop(n, x) do
    nx = div(div(n, x) + x, 2)
    if nx >= x, do: x, else: isqrt_loop(n, nx)
  end

  defp exact_to_inexact([n]), do: to_inexact("exact->inexact", n)
  defp inexact_([n]), do: to_inexact("inexact", n)

  defp inexact_to_exact([n]), do: to_exact("inexact->exact", n)
  defp exact_([n]), do: to_exact("exact", n)

  defp to_inexact(op, n) do
    require_number!(op, n)
    if is_special(n), do: n, else: to_float(n)
  end

  defp to_exact(_op, n) when is_integer(n), do: n
  defp to_exact(_op, {:rational, _, _} = r), do: r

  defp to_exact(_op, n) when is_float(n), do: float_to_exact(n)

  defp to_exact(_op, {:float_special, _} = n) do
    raise Error, reason: {:not_representable_exact, n}
  end

  defp to_exact(op, other) do
    raise Error, reason: {:type_error, op, "number", other}
  end

  # Bit-exact IEEE-754 → exact rational via `Float.ratio/1`. The signed-zero
  # case is handled here because `Float.ratio(-0.0)` returns the giant
  # subnormal pair `{0, 1 <<< 1074}` rather than `{0, 1}`; non-finite
  # operands are filtered earlier by `to_exact/2`.
  defp float_to_exact(f) when f == 0.0, do: 0

  defp float_to_exact(f) when is_float(f) do
    {n, d} = Float.ratio(f)
    Value.rational(n, d)
  end

  # ---------------------------------------------------------------------------
  # numerator / denominator / rationalize
  # ---------------------------------------------------------------------------

  defp numerator_([n]) when is_integer(n), do: n
  defp numerator_([{:rational, n, _}]), do: n
  defp numerator_([f]) when is_float(f), do: elem(Float.ratio(f), 0) * 1.0
  defp numerator_([{:float_special, _} = s]), do: s
  defp numerator_([other]), do: raise_rational_required("numerator", other)

  defp denominator_([n]) when is_integer(n), do: 1
  defp denominator_([{:rational, _, d}]), do: d
  defp denominator_([f]) when is_float(f), do: elem(Float.ratio(f), 1) * 1.0
  defp denominator_([{:float_special, :nan} = s]), do: s
  defp denominator_([{:float_special, _}]), do: 1.0
  defp denominator_([other]), do: raise_rational_required("denominator", other)

  defp raise_rational_required(op, other),
    do: raise(Error, reason: {:type_error, op, "rational", other})

  # Stern-Brocot / continued-fraction simplest-rational. Operates on exact
  # values; the wrapper widens float operands to exact, runs the algorithm,
  # and narrows back so the result tracks input exactness as r7rs requires.
  defp rationalize_([x, y]) do
    require_number!("rationalize", x)
    require_number!("rationalize", y)
    do_rationalize(x, y)
  end

  defp do_rationalize({:float_special, :nan}, _), do: {:float_special, :nan}
  defp do_rationalize(_, {:float_special, :nan}), do: {:float_special, :nan}
  defp do_rationalize({:float_special, _} = v, _), do: v
  # Infinite tolerance covers the entire real line; the simplest rational
  # in any such interval is 0. Inexact `y` widens the result to inexact.
  defp do_rationalize(_x, {:float_special, _}), do: 0.0

  defp do_rationalize(x, y) do
    inexact? = is_float(x) or is_float(y)
    ex = if inexact?, do: float_to_exact(to_float(x)), else: x
    ey = if inexact?, do: float_to_exact(to_float(y)), else: y
    result = simplest_rational(ex, ey)
    if inexact?, do: to_float(result), else: result
  end

  defp simplest_rational(x, y) do
    # |y| is the tolerance; the simplest rational lies in [x - |y|, x + |y|].
    abs_y = abs_special(y)
    lo = sub_pair(x, abs_y)
    hi = add_pair(x, abs_y)

    cond do
      not rat_lt(lo, 0) -> simplest_rational_pos(lo, hi)
      not rat_lt(0, hi) -> negate(simplest_rational_pos(negate(hi), negate(lo)))
      true -> 0
    end
  end

  defp simplest_rational_pos(lo, hi) do
    flo = rat_floor(lo)
    fhi = rat_floor(hi)

    cond do
      rat_eq(flo, lo) ->
        flo

      rat_eq(flo, fhi) ->
        inv_lo = rat_div(1, sub_pair(lo, flo))
        inv_hi = rat_div(1, sub_pair(hi, fhi))
        add_pair(flo, rat_div(1, simplest_rational_pos(inv_hi, inv_lo)))

      true ->
        add_pair(flo, 1)
    end
  end

  defp rat_floor(n) when is_integer(n), do: n
  defp rat_floor({:rational, n, d}), do: Integer.floor_div(n, d)

  # ---------------------------------------------------------------------------
  # Comparison
  # ---------------------------------------------------------------------------

  defp comparison_specs do
    [
      {"=", {:at_least, 1}, &cmp_eq/1},
      {"<", {:at_least, 1}, &cmp_lt/1},
      {">", {:at_least, 1}, &cmp_gt/1},
      {"<=", {:at_least, 1}, &cmp_le/1},
      {">=", {:at_least, 1}, &cmp_ge/1}
    ]
  end

  defp cmp_eq(args), do: variadic_cmp("=", args, &num_eq/2, &require_number!/2)
  defp cmp_lt(args), do: variadic_cmp("<", args, &num_lt/2, &require_real!/2)
  defp cmp_gt(args), do: variadic_cmp(">", args, &num_gt/2, &require_real!/2)
  defp cmp_le(args), do: variadic_cmp("<=", args, &num_le/2, &require_real!/2)
  defp cmp_ge(args), do: variadic_cmp(">=", args, &num_ge/2, &require_real!/2)

  defp variadic_cmp(op, [first | rest], pair, type_check) do
    type_check.(op, first)
    Value.bool(check_pairs(rest, first, op, pair, type_check))
  end

  defp check_pairs([], _prev, _op, _pair, _type_check), do: true

  defp check_pairs([b | rest], prev, op, pair, type_check) do
    type_check.(op, b)
    # IEEE-754: any comparison against NaN is "unordered" → false.
    cond do
      prev == {:float_special, :nan} -> false
      b == {:float_special, :nan} -> false
      pair.(prev, b) -> check_pairs(rest, b, op, pair, type_check)
      true -> false
    end
  end

  # `=` is numerical equality; `(= 1 1.0)` is true (only `eqv?` cares about
  # exactness). Complex equality compares both rectangular components,
  # falling back to numerical equality on each part — so `(= 1 1+0i)` is
  # true (the rhs collapses to `1` on construction, but a hand-built
  # `{:complex, 1, 0}` would still match).
  defp num_eq(a, b) when is_complex(a) or is_complex(b), do: complex_eq(a, b)
  defp num_eq(a, b) when is_special(a) or is_special(b), do: special_cmp_eq(a, b)
  defp num_eq(a, b) when is_float(a) or is_float(b), do: to_float(a) == to_float(b)
  defp num_eq(a, b), do: rat_eq(a, b)

  defp complex_eq(a, b) do
    {ar, ai} = complex_pair(a)
    {br, bi} = complex_pair(b)
    num_eq(ar, br) and num_eq(ai, bi)
  end

  defp num_lt(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) == :lt
  defp num_lt(a, b) when is_float(a) or is_float(b), do: to_float(a) < to_float(b)
  defp num_lt(a, b), do: rat_lt(a, b)

  defp num_gt(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) == :gt
  defp num_gt(a, b) when is_float(a) or is_float(b), do: to_float(a) > to_float(b)
  defp num_gt(a, b), do: rat_lt(b, a)

  defp num_le(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) in [:lt, :eq]
  defp num_le(a, b) when is_float(a) or is_float(b), do: to_float(a) <= to_float(b)
  defp num_le(a, b), do: not rat_lt(b, a)

  defp num_ge(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) in [:gt, :eq]
  defp num_ge(a, b) when is_float(a) or is_float(b), do: to_float(a) >= to_float(b)
  defp num_ge(a, b), do: not rat_lt(a, b)

  # Reduced rationals are structurally unique, so `===` decides equality on
  # the entire (integer | rational) lattice — `Value.rational/2` collapses
  # any `n/1` to a bare integer, and rationals share no shape with anything
  # else here.
  defp rat_eq(a, b), do: a === b

  defp rat_lt(a, b) when is_integer(a) and is_integer(b), do: a < b

  defp rat_lt(a, b) do
    {n1, d1} = rat_pair(a)
    {n2, d2} = rat_pair(b)
    # both denominators are positive, so cross-multiplication preserves inequality.
    n1 * d2 < n2 * d1
  end

  # Equality and ordering between specials and finite reals (NaN handled
  # in `check_pairs/4`; not reached here for the generic comparison ops).
  defp special_cmp_eq({:float_special, k}, {:float_special, k}), do: true
  defp special_cmp_eq(_, _), do: false

  defp special_cmp({:float_special, :pos_inf}, {:float_special, :pos_inf}), do: :eq
  defp special_cmp({:float_special, :neg_inf}, {:float_special, :neg_inf}), do: :eq
  defp special_cmp({:float_special, :pos_inf}, _), do: :gt
  defp special_cmp({:float_special, :neg_inf}, _), do: :lt
  defp special_cmp(_, {:float_special, :pos_inf}), do: :lt
  defp special_cmp(_, {:float_special, :neg_inf}), do: :gt

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  defp predicate_specs do
    [
      {"number?", 1, &number_p/1},
      {"complex?", 1, &complex_p/1},
      {"real?", 1, &real_p/1},
      {"integer?", 1, &integer_p/1},
      {"rational?", 1, &rational_p/1},
      {"exact?", 1, &exact_p/1},
      {"inexact?", 1, &inexact_p/1},
      {"zero?", 1, &zero_p/1},
      {"positive?", 1, &positive_p/1},
      {"negative?", 1, &negative_p/1},
      {"odd?", 1, &odd_p/1},
      {"even?", 1, &even_p/1},
      {"boolean?", 1, &boolean_p/1},
      {"pair?", 1, &pair_p/1},
      {"null?", 1, &null_p/1},
      {"list?", 1, &list_p/1},
      {"symbol?", 1, &symbol_p/1},
      {"string?", 1, &string_p/1},
      {"char?", 1, &char_p/1},
      {"vector?", 1, &vector_p/1},
      {"bytevector?", 1, &bytevector_p/1},
      {"procedure?", 1, &procedure_p/1},
      {"eof-object?", 1, &eof_p/1},
      {"eq?", 2, &eq_p/1},
      {"eqv?", 2, &eqv_p/1},
      {"equal?", 2, &equal_p/1}
    ]
  end

  defp number_p([v]), do: Value.bool(Value.number?(v))
  defp complex_p([v]), do: Value.bool(Value.complex?(v))
  defp real_p([v]), do: Value.bool(Value.real?(v))
  defp integer_p([v]), do: Value.bool(Value.integer?(v))
  defp rational_p([v]), do: Value.bool(Value.rational?(v))
  defp exact_p([v]), do: Value.bool(Value.exact?(v))
  defp inexact_p([v]), do: Value.bool(Value.inexact?(v))
  defp boolean_p([v]), do: Value.bool(Value.boolean?(v))
  defp pair_p([v]), do: Value.bool(Value.pair?(v))
  defp null_p([v]), do: Value.bool(Value.null?(v))
  defp list_p([v]), do: Value.bool(Value.list?(v))
  defp symbol_p([v]), do: Value.bool(Value.symbol?(v))
  defp string_p([v]), do: Value.bool(Value.string?(v))
  defp char_p([v]), do: Value.bool(Value.char?(v))
  defp vector_p([v]), do: Value.bool(Value.vector?(v))
  defp bytevector_p([v]), do: Value.bool(Value.bytevector?(v))
  defp procedure_p([v]), do: Value.bool(Value.procedure?(v))
  defp eof_p([v]), do: Value.bool(Value.eof?(v))

  defp eq_p([a, b]), do: Value.bool(Value.eq?(a, b))
  defp eqv_p([a, b]), do: Value.bool(Value.eqv?(a, b))
  defp equal_p([a, b]), do: Value.bool(Value.equal?(a, b))

  defp zero_p([n]) do
    require_number!("zero?", n)
    Value.bool(numeric_zero?(n))
  end

  defp numeric_zero?({:complex, r, i}), do: numeric_zero?(r) and numeric_zero?(i)
  defp numeric_zero?(n) when is_special(n), do: false
  defp numeric_zero?(n), do: n == 0

  defp positive_p([{:float_special, :pos_inf}]), do: Value.bool(true)
  defp positive_p([{:float_special, _}]), do: Value.bool(false)
  defp positive_p([{:rational, n, _}]), do: Value.bool(n > 0)

  defp positive_p([n]) do
    require_real!("positive?", n)
    Value.bool(n > 0)
  end

  defp negative_p([{:float_special, :neg_inf}]), do: Value.bool(true)
  defp negative_p([{:float_special, _}]), do: Value.bool(false)
  defp negative_p([{:rational, n, _}]), do: Value.bool(n < 0)

  defp negative_p([n]) do
    require_real!("negative?", n)
    Value.bool(n < 0)
  end

  defp odd_p([n]) do
    require_integer!("odd?", n)
    Value.bool(rem(trunc_int(n), 2) != 0)
  end

  defp even_p([n]) do
    require_integer!("even?", n)
    Value.bool(rem(trunc_int(n), 2) == 0)
  end

  # ---------------------------------------------------------------------------
  # Boolean
  # ---------------------------------------------------------------------------

  defp boolean_specs do
    [
      {"not", 1, &not_p/1},
      {"boolean=?", {:at_least, 2}, &boolean_equal/1}
    ]
  end

  defp not_p([v]), do: Value.bool(not Value.truthy?(v))

  defp boolean_equal([first | rest] = args) do
    Enum.each(args, fn
      b when is_boolean(b) -> :ok
      other -> raise(Error, reason: {:type_error, "boolean=?", "boolean", other})
    end)

    Value.bool(Enum.all?(rest, &(&1 === first)))
  end

  # ---------------------------------------------------------------------------
  # Pairs and lists
  # ---------------------------------------------------------------------------

  defp pair_specs do
    [
      {"cons", 2, &cons_/1},
      {"car", 1, &car_/1},
      {"cdr", 1, &cdr_/1},
      {"list", {:at_least, 0}, &list_ctor/1},
      {"list-copy", 1, &list_copy/1},
      {"length", 1, &length_/1},
      {"reverse", 1, &reverse_/1},
      {"append", {:at_least, 0}, &append_/1},
      {"list-tail", 2, &list_tail/1},
      {"list-ref", 2, &list_ref/1},
      {"member", 2, &member_/1},
      {"memv", 2, &memv_/1},
      {"memq", 2, &memq_/1},
      {"assoc", 2, &assoc_/1},
      {"assv", 2, &assv_/1},
      {"assq", 2, &assq_/1},
      {"map", {:at_least, 2}, &map_/1},
      {"for-each", {:at_least, 2}, &for_each_/1},
      {"apply", {:at_least, 2}, &apply_/1}
    ]
  end

  defp cons_([a, b]), do: Value.pair(a, b)

  defp car_([[a | _]]), do: a
  defp car_([other]), do: raise(Error, reason: {:type_error, "car", "pair", other})

  defp cdr_([[_ | b]]), do: b
  defp cdr_([other]), do: raise(Error, reason: {:type_error, "cdr", "pair", other})

  defp list_ctor(args), do: Value.list(args)

  # r7rs §6.4: returns a freshly-allocated copy of the list spine.
  # Improper tails are accepted and preserved as-is (only the cons
  # cells are copied, the elements themselves are shared).
  defp list_copy([list]), do: do_list_copy(list)

  defp do_list_copy([h | t]), do: [h | do_list_copy(t)]
  defp do_list_copy(other), do: other

  defp length_([list]) do
    case proper_length(list, 0) do
      {:ok, n} -> n
      :error -> raise(Error, reason: {:improper_list, "length", list})
    end
  end

  defp proper_length([], n), do: {:ok, n}
  defp proper_length([_ | t], n), do: proper_length(t, n + 1)
  defp proper_length(_, _), do: :error

  defp reverse_([list]), do: do_reverse(list, [])

  defp do_reverse([], acc), do: acc
  defp do_reverse([h | t], acc), do: do_reverse(t, [h | acc])
  defp do_reverse(other, _acc), do: raise(Error, reason: {:improper_list, "reverse", other})

  # `(append a b c)` ⇒ all but the last must be proper lists; the last is
  # spliced in as-is, so it can be any value (including an improper tail).
  defp append_([]), do: []
  defp append_([only]), do: only

  defp append_(args) do
    {fronts, [last]} = Enum.split(args, length(args) - 1)
    Enum.each(fronts, &require_proper_list!("append", &1))
    do_append(fronts, last)
  end

  defp do_append([], tail), do: tail
  defp do_append([list | rest], tail), do: append_pair(list, do_append(rest, tail))

  defp append_pair([], tail), do: tail
  defp append_pair([h | t], tail), do: [h | append_pair(t, tail)]

  defp list_tail([list, k]) do
    require_integer!("list-tail", k)
    if k < 0, do: raise(Error, reason: {:index_out_of_range, "list-tail", k, "n/a"})
    do_list_tail(list, trunc_int(k), 0)
  end

  defp do_list_tail(rest, 0, _consumed), do: rest

  defp do_list_tail([_ | t], k, consumed),
    do: do_list_tail(t, k - 1, consumed + 1)

  defp do_list_tail(_other, k, consumed) do
    raise(Error, reason: {:index_out_of_range, "list-tail", consumed + k, consumed})
  end

  defp list_ref([list, k]) do
    require_integer!("list-ref", k)
    if k < 0, do: raise(Error, reason: {:index_out_of_range, "list-ref", k, "n/a"})
    do_list_ref(list, trunc_int(k), 0)
  end

  defp do_list_ref([h | _], 0, _consumed), do: h

  defp do_list_ref([_ | t], k, consumed),
    do: do_list_ref(t, k - 1, consumed + 1)

  defp do_list_ref(_other, k, consumed) do
    raise(Error, reason: {:index_out_of_range, "list-ref", consumed + k, consumed})
  end

  defp member_([obj, list]), do: do_member("member", obj, list, &Value.equal?/2)
  defp memv_([obj, list]), do: do_member("memv", obj, list, &Value.eqv?/2)
  defp memq_([obj, list]), do: do_member("memq", obj, list, &Value.eq?/2)

  defp do_member(_op, _obj, [], _eq), do: Value.bool(false)

  defp do_member(op, obj, [h | t] = pair, eq) do
    if eq.(obj, h), do: pair, else: do_member(op, obj, t, eq)
  end

  defp do_member(op, _obj, other, _eq) do
    raise(Error, reason: {:improper_list, op, other})
  end

  defp assoc_([obj, list]), do: do_assoc("assoc", obj, list, &Value.equal?/2)
  defp assv_([obj, list]), do: do_assoc("assv", obj, list, &Value.eqv?/2)
  defp assq_([obj, list]), do: do_assoc("assq", obj, list, &Value.eq?/2)

  defp do_assoc(_op, _obj, [], _eq), do: Value.bool(false)

  defp do_assoc(op, obj, [[k | _] = entry | rest], eq) do
    if eq.(obj, k), do: entry, else: do_assoc(op, obj, rest, eq)
  end

  defp do_assoc(op, _obj, [other | _], _eq) do
    raise(Error, reason: {:type_error, op, "pair as alist entry", other})
  end

  defp do_assoc(op, _obj, other, _eq) do
    raise(Error, reason: {:improper_list, op, other})
  end

  defp map_([proc | lists]) do
    require_procedure!("map", proc)
    Enum.each(lists, &require_proper_list!("map", &1))
    Value.list(do_zip_apply(proc, lists, []))
  end

  defp for_each_([proc | lists]) do
    require_procedure!("for-each", proc)
    Enum.each(lists, &require_proper_list!("for-each", &1))
    _ = do_zip_apply(proc, lists, [])
    :unspecified
  end

  defp do_zip_apply(proc, lists, acc) do
    case split_heads_tails(lists, [], []) do
      :exhausted -> Enum.reverse(acc)
      {heads, tails} -> do_zip_apply(proc, tails, [Eval.apply_proc(proc, heads) | acc])
    end
  end

  defp split_heads_tails([], hs, ts), do: {Enum.reverse(hs), Enum.reverse(ts)}
  defp split_heads_tails([[] | _], _hs, _ts), do: :exhausted

  defp split_heads_tails([[h | t] | r], hs, ts),
    do: split_heads_tails(r, [h | hs], [t | ts])

  # r7rs §6.10: `(apply proc arg1 ... argn list)`. The leading args are
  # passed positionally, the trailing list is spliced. The tail call to
  # `Eval.apply_proc/2` keeps the proper-tail-call invariant intact —
  # an `apply` use in tail position behaves like a direct call.
  defp apply_([proc | rest]) do
    require_procedure!("apply", proc)
    Eval.apply_proc(proc, build_apply_args(rest))
  end

  defp build_apply_args([list]) do
    require_proper_list!("apply", list)
    flatten_scheme_list(list, [])
  end

  defp build_apply_args([head | rest]), do: [head | build_apply_args(rest)]

  defp flatten_scheme_list([], acc), do: Enum.reverse(acc)
  defp flatten_scheme_list([h | t], acc), do: flatten_scheme_list(t, [h | acc])

  # ---------------------------------------------------------------------------
  # Vectors
  # ---------------------------------------------------------------------------

  defp vector_specs do
    [
      {"vector", {:at_least, 0}, &vector_ctor/1},
      {"make-vector", {:at_least, 1}, &make_vector/1},
      {"vector-length", 1, &vector_length/1},
      {"vector-ref", 2, &vector_ref/1},
      {"vector->list", {:at_least, 1}, &vector_to_list/1},
      {"list->vector", 1, &list_to_vector/1},
      {"vector-map", {:at_least, 2}, &vector_map/1},
      {"vector-for-each", {:at_least, 2}, &vector_for_each/1},
      {"vector-copy", {:at_least, 1}, &vector_copy/1},
      {"vector-append", {:at_least, 0}, &vector_append/1}
    ]
  end

  defp vector_ctor(args), do: Value.vector(args)

  defp make_vector([k]), do: make_vector([k, :unspecified])

  defp make_vector([k, fill]) do
    n = require_size!("make-vector", k)
    Value.vector(List.duplicate(fill, n))
  end

  defp make_vector([_, _ | _]) do
    raise(Error, reason: {:type_error, "make-vector", "1 or 2 arguments", :too_many})
  end

  defp vector_length([{:vector, t}]), do: tuple_size(t)

  defp vector_length([other]),
    do: raise(Error, reason: {:type_error, "vector-length", "vector", other})

  defp vector_ref([{:vector, t}, k]) do
    i = require_index!("vector-ref", k, tuple_size(t))
    elem(t, i)
  end

  defp vector_ref([other, _]),
    do: raise(Error, reason: {:type_error, "vector-ref", "vector", other})

  defp vector_to_list([{:vector, t}]) do
    Value.list(Tuple.to_list(t))
  end

  defp vector_to_list([{:vector, t}, start]) do
    n = tuple_size(t)
    s = require_bound!("vector->list", start, 0, n)
    Value.list(Enum.map(s..(n - 1)//1, &elem(t, &1)))
  end

  defp vector_to_list([{:vector, t}, start, end_]) do
    n = tuple_size(t)
    s = require_bound!("vector->list", start, 0, n)
    e = require_bound!("vector->list", end_, s, n)
    Value.list(Enum.map(s..(e - 1)//1, &elem(t, &1)))
  end

  defp vector_to_list([other | _]),
    do: raise(Error, reason: {:type_error, "vector->list", "vector", other})

  defp list_to_vector([list]) do
    Value.vector(scheme_list_to_elixir!("list->vector", list))
  end

  defp vector_map([proc | vectors]) do
    require_procedure!("vector-map", proc)
    Enum.each(vectors, &require_vector!("vector-map", &1))
    tuples = Enum.map(vectors, fn {:vector, t} -> t end)
    n = tuples |> Enum.map(&tuple_size/1) |> Enum.min()

    results =
      Enum.map(0..(n - 1)//1, fn i ->
        Eval.apply_proc(proc, Enum.map(tuples, &elem(&1, i)))
      end)

    Value.vector(results)
  end

  defp vector_for_each([proc | vectors]) do
    require_procedure!("vector-for-each", proc)
    Enum.each(vectors, &require_vector!("vector-for-each", &1))
    tuples = Enum.map(vectors, fn {:vector, t} -> t end)
    n = tuples |> Enum.map(&tuple_size/1) |> Enum.min()

    Enum.each(0..(n - 1)//1, fn i ->
      Eval.apply_proc(proc, Enum.map(tuples, &elem(&1, i)))
    end)

    :unspecified
  end

  defp vector_copy([v]), do: vector_copy_range(v, nil, nil)
  defp vector_copy([v, start]), do: vector_copy_range(v, start, nil)
  defp vector_copy([v, start, end_]), do: vector_copy_range(v, start, end_)

  defp vector_copy([_, _, _, _ | _]) do
    raise(Error, reason: {:type_error, "vector-copy", "1 to 3 arguments", :too_many})
  end

  defp vector_copy_range({:vector, t}, start, end_) do
    n = tuple_size(t)
    s = if start == nil, do: 0, else: require_bound!("vector-copy", start, 0, n)
    e = if end_ == nil, do: n, else: require_bound!("vector-copy", end_, s, n)
    Value.vector(Enum.map(s..(e - 1)//1, &elem(t, &1)))
  end

  defp vector_copy_range(other, _, _),
    do: raise(Error, reason: {:type_error, "vector-copy", "vector", other})

  defp vector_append(args) do
    Enum.each(args, &require_vector!("vector-append", &1))

    items =
      args
      |> Enum.flat_map(fn {:vector, t} -> Tuple.to_list(t) end)

    Value.vector(items)
  end

  # ---------------------------------------------------------------------------
  # Bytevectors
  # ---------------------------------------------------------------------------

  defp bytevector_specs do
    [
      {"bytevector", {:at_least, 0}, &bytevector_ctor/1},
      {"make-bytevector", {:at_least, 1}, &make_bytevector/1},
      {"bytevector-length", 1, &bytevector_length/1},
      {"bytevector-u8-ref", 2, &bytevector_u8_ref/1},
      {"bytevector-copy", {:at_least, 1}, &bytevector_copy/1},
      {"bytevector-append", {:at_least, 0}, &bytevector_append/1},
      {"utf8->string", {:at_least, 1}, &utf8_to_string/1},
      {"string->utf8", {:at_least, 1}, &string_to_utf8/1}
    ]
  end

  defp bytevector_ctor(args) do
    bytes = Enum.map(args, &require_byte!("bytevector", &1))
    Value.bytevector(bytes)
  end

  defp make_bytevector([k]), do: make_bytevector([k, 0])

  defp make_bytevector([k, fill]) do
    n = require_size!("make-bytevector", k)
    b = require_byte!("make-bytevector", fill)
    Value.bytevector(:binary.copy(<<b>>, n))
  end

  defp make_bytevector([_, _ | _]) do
    raise(Error, reason: {:type_error, "make-bytevector", "1 or 2 arguments", :too_many})
  end

  defp bytevector_length([{:bytevector, b}]), do: byte_size(b)

  defp bytevector_length([other]),
    do: raise(Error, reason: {:type_error, "bytevector-length", "bytevector", other})

  defp bytevector_u8_ref([{:bytevector, b}, k]) do
    i = require_index!("bytevector-u8-ref", k, byte_size(b))
    :binary.at(b, i)
  end

  defp bytevector_u8_ref([other, _]),
    do: raise(Error, reason: {:type_error, "bytevector-u8-ref", "bytevector", other})

  defp bytevector_copy([v]), do: bytevector_copy_range(v, nil, nil)
  defp bytevector_copy([v, start]), do: bytevector_copy_range(v, start, nil)
  defp bytevector_copy([v, start, end_]), do: bytevector_copy_range(v, start, end_)

  defp bytevector_copy([_, _, _, _ | _]) do
    raise(Error, reason: {:type_error, "bytevector-copy", "1 to 3 arguments", :too_many})
  end

  defp bytevector_copy_range({:bytevector, b}, start, end_) do
    n = byte_size(b)
    s = if start == nil, do: 0, else: require_bound!("bytevector-copy", start, 0, n)
    e = if end_ == nil, do: n, else: require_bound!("bytevector-copy", end_, s, n)
    Value.bytevector(:binary.part(b, s, e - s))
  end

  defp bytevector_copy_range(other, _, _),
    do: raise(Error, reason: {:type_error, "bytevector-copy", "bytevector", other})

  defp bytevector_append(args) do
    Enum.each(args, &require_bytevector!("bytevector-append", &1))
    bins = Enum.map(args, fn {:bytevector, b} -> b end)
    Value.bytevector(IO.iodata_to_binary(bins))
  end

  defp utf8_to_string([v]), do: utf8_to_string_range(v, nil, nil)
  defp utf8_to_string([v, start]), do: utf8_to_string_range(v, start, nil)
  defp utf8_to_string([v, start, end_]), do: utf8_to_string_range(v, start, end_)

  defp utf8_to_string([_, _, _, _ | _]) do
    raise(Error, reason: {:type_error, "utf8->string", "1 to 3 arguments", :too_many})
  end

  defp utf8_to_string_range({:bytevector, b}, start, end_) do
    n = byte_size(b)
    s = if start == nil, do: 0, else: require_bound!("utf8->string", start, 0, n)
    e = if end_ == nil, do: n, else: require_bound!("utf8->string", end_, s, n)
    slice = :binary.part(b, s, e - s)

    if String.valid?(slice),
      do: Value.string(slice),
      else: raise(Error, reason: {:invalid_utf8, "utf8->string"})
  end

  defp utf8_to_string_range(other, _, _),
    do: raise(Error, reason: {:type_error, "utf8->string", "bytevector", other})

  defp string_to_utf8([v]), do: string_to_utf8_range(v, nil, nil)
  defp string_to_utf8([v, start]), do: string_to_utf8_range(v, start, nil)
  defp string_to_utf8([v, start, end_]), do: string_to_utf8_range(v, start, end_)

  defp string_to_utf8([_, _, _, _ | _]) do
    raise(Error, reason: {:type_error, "string->utf8", "1 to 3 arguments", :too_many})
  end

  defp string_to_utf8_range(s, start, end_) when is_binary(s) do
    {sbyte, slen} = string_byte_slice(s, start || 0, end_, "string->utf8")
    Value.bytevector(:binary.part(s, sbyte, slen))
  end

  defp string_to_utf8_range(other, _, _),
    do: raise(Error, reason: {:type_error, "string->utf8", "string", other})

  # ---------------------------------------------------------------------------
  # Strings
  # ---------------------------------------------------------------------------

  defp string_specs do
    [
      {"string", {:at_least, 0}, &string_ctor/1},
      {"make-string", {:at_least, 1}, &make_string/1},
      {"string-length", 1, &string_length/1},
      {"string-ref", 2, &string_ref/1},
      {"string-append", {:at_least, 0}, &string_append/1},
      {"substring", 3, &substring_/1},
      {"string=?", {:at_least, 2}, &string_eq/1},
      {"string<?", {:at_least, 2}, &string_lt/1},
      {"string<=?", {:at_least, 2}, &string_le/1},
      {"string>?", {:at_least, 2}, &string_gt/1},
      {"string>=?", {:at_least, 2}, &string_ge/1},
      {"string->list", {:at_least, 1}, &string_to_list/1},
      {"list->string", 1, &list_to_string/1},
      {"string-upcase", 1, &string_upcase/1},
      {"string-downcase", 1, &string_downcase/1},
      {"string-copy", {:at_least, 1}, &string_copy/1}
    ]
  end

  defp string_ctor(args) do
    bytes =
      args
      |> Enum.map(&require_char!("string", &1))
      |> Enum.map(&codepoint_to_utf8/1)

    Value.string(IO.iodata_to_binary(bytes))
  end

  defp make_string([k]), do: make_string([k, Value.char(?\s)])

  defp make_string([k, char]) do
    n = require_size!("make-string", k)
    cp = require_char!("make-string", char)
    Value.string(:binary.copy(codepoint_to_utf8(cp), n))
  end

  defp make_string([_, _ | _]) do
    raise(Error, reason: {:type_error, "make-string", "1 or 2 arguments", :too_many})
  end

  defp string_length([s]) when is_binary(s), do: string_codepoint_length(s)

  defp string_length([other]),
    do: raise(Error, reason: {:type_error, "string-length", "string", other})

  defp string_ref([s, k]) when is_binary(s) do
    require_integer!("string-ref", k)
    i = trunc_int(k)
    if i < 0, do: raise_index!("string-ref", i, s)

    case nth_codepoint(s, i) do
      {:ok, cp} -> Value.char(cp)
      :end -> raise_index!("string-ref", i, s)
    end
  end

  defp string_ref([other, _]),
    do: raise(Error, reason: {:type_error, "string-ref", "string", other})

  defp string_append(args) do
    Enum.each(args, &require_string!("string-append", &1))
    Value.string(IO.iodata_to_binary(args))
  end

  defp substring_([s, start, end_]) when is_binary(s) do
    {sbyte, slen} = string_byte_slice(s, start, end_, "substring")
    Value.string(:binary.part(s, sbyte, slen))
  end

  defp substring_([other, _, _]),
    do: raise(Error, reason: {:type_error, "substring", "string", other})

  defp string_eq(args), do: variadic_string_cmp("string=?", args, &(&1 == &2))
  defp string_lt(args), do: variadic_string_cmp("string<?", args, &(&1 < &2))
  defp string_le(args), do: variadic_string_cmp("string<=?", args, &(&1 <= &2))
  defp string_gt(args), do: variadic_string_cmp("string>?", args, &(&1 > &2))
  defp string_ge(args), do: variadic_string_cmp("string>=?", args, &(&1 >= &2))

  defp variadic_string_cmp(op, [first | rest] = args, pair) do
    Enum.each(args, &require_string!(op, &1))
    Value.bool(check_string_pairs(rest, first, pair))
  end

  defp check_string_pairs([], _prev, _pair), do: true

  defp check_string_pairs([s | rest], prev, pair) when is_binary(s) and is_binary(prev) do
    if pair.(prev, s), do: check_string_pairs(rest, s, pair), else: false
  end

  defp string_to_list([v]), do: string_to_list_range(v, nil, nil)
  defp string_to_list([v, start]), do: string_to_list_range(v, start, nil)
  defp string_to_list([v, start, end_]), do: string_to_list_range(v, start, end_)

  defp string_to_list([_, _, _, _ | _]) do
    raise(Error, reason: {:type_error, "string->list", "1 to 3 arguments", :too_many})
  end

  defp string_to_list_range(s, start, end_) when is_binary(s) do
    cps = slice_codepoints(s, start || 0, end_, "string->list")
    Value.list(Enum.map(cps, &Value.char/1))
  end

  defp string_to_list_range(other, _, _),
    do: raise(Error, reason: {:type_error, "string->list", "string", other})

  defp list_to_string([list]) do
    bytes =
      "list->string"
      |> scheme_list_to_elixir!(list)
      |> Enum.map(&require_char!("list->string", &1))
      |> Enum.map(&codepoint_to_utf8/1)

    Value.string(IO.iodata_to_binary(bytes))
  end

  defp string_upcase([s]) when is_binary(s), do: Value.string(String.upcase(s, :default))

  defp string_upcase([other]),
    do: raise(Error, reason: {:type_error, "string-upcase", "string", other})

  defp string_downcase([s]) when is_binary(s), do: Value.string(String.downcase(s, :default))

  defp string_downcase([other]),
    do: raise(Error, reason: {:type_error, "string-downcase", "string", other})

  defp string_copy([v]), do: string_copy_range(v, nil, nil)
  defp string_copy([v, start]), do: string_copy_range(v, start, nil)
  defp string_copy([v, start, end_]), do: string_copy_range(v, start, end_)

  defp string_copy([_, _, _, _ | _]) do
    raise(Error, reason: {:type_error, "string-copy", "1 to 3 arguments", :too_many})
  end

  defp string_copy_range(s, nil, nil) when is_binary(s), do: Value.string(s)

  defp string_copy_range(s, start, end_) when is_binary(s) do
    {sbyte, slen} = string_byte_slice(s, start || 0, end_, "string-copy")
    Value.string(:binary.part(s, sbyte, slen))
  end

  defp string_copy_range(other, _, _),
    do: raise(Error, reason: {:type_error, "string-copy", "string", other})

  # ---------------------------------------------------------------------------
  # Symbols
  # ---------------------------------------------------------------------------

  defp symbol_specs do
    [
      {"symbol=?", {:at_least, 2}, &symbol_eq/1},
      {"symbol->string", 1, &symbol_to_string/1},
      {"string->symbol", 1, &string_to_symbol/1}
    ]
  end

  defp symbol_eq([first | _] = args) do
    Enum.each(args, fn
      {:sym, _} -> :ok
      other -> raise(Error, reason: {:type_error, "symbol=?", "symbol", other})
    end)

    Value.bool(Enum.all?(args, &(&1 === first)))
  end

  defp symbol_to_string([{:sym, name}]), do: Value.string(name)

  defp symbol_to_string([other]),
    do: raise(Error, reason: {:type_error, "symbol->string", "symbol", other})

  defp string_to_symbol([s]) when is_binary(s), do: Value.symbol(s)

  defp string_to_symbol([other]),
    do: raise(Error, reason: {:type_error, "string->symbol", "string", other})

  # ---------------------------------------------------------------------------
  # Multi-value returns
  # ---------------------------------------------------------------------------
  #
  # `(values v ...)` produces a `{:values, vs}` transit marker that
  # only `call-with-values` destructures; everywhere else
  # `Eval.single_value!/1` either unwraps the 1-element case or
  # raises `{:wrong_value_count, …}`. The `:values` tag is unique to
  # this marker — no Scheme value carries it — so the payload can be
  # a plain list without shape-collision risk.

  defp multi_value_specs do
    [
      {"values", {:at_least, 0}, &values_proc/1},
      {"call-with-values", 2, &call_with_values_proc/1}
    ]
  end

  defp values_proc(args), do: {:values, args}

  defp call_with_values_proc([producer, consumer]) do
    case Eval.apply_proc(producer, []) do
      {:values, vs} -> Eval.apply_proc(consumer, vs)
      single -> Eval.apply_proc(consumer, [single])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp reduce_numeric(op, args, acc, op_fn) do
    Enum.reduce(args, acc, fn x, a ->
      require_number!(op, x)
      op_fn.(a, x)
    end)
  end

  defp require_number!(_op, n) when is_integer(n) or is_float(n), do: :ok
  defp require_number!(_op, n) when is_special(n) or is_rational(n) or is_complex(n), do: :ok

  defp require_number!(op, other) do
    raise Error, reason: {:type_error, op, "number", other}
  end

  defp require_real!(_op, n) when is_real_v(n), do: :ok

  defp require_real!(op, other) do
    raise Error, reason: {:type_error, op, "real number", other}
  end

  defp require_integer!(_op, n) when is_integer(n), do: :ok

  defp require_integer!(op, n) when is_float(n) do
    if Value.integer?(n), do: :ok, else: raise(Error, reason: {:type_error, op, "integer", n})
  end

  defp require_integer!(op, other) do
    raise Error, reason: {:type_error, op, "integer", other}
  end

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float({:rational, n, d}), do: n / d

  defp trunc_int(n) when is_integer(n), do: n
  defp trunc_int(n) when is_float(n), do: trunc(n)

  defp signum(0), do: 0
  defp signum(n) when n > 0, do: 1
  defp signum(_), do: -1

  defp coerce_int_result(a, b, n) when is_float(a) or is_float(b), do: n * 1.0
  defp coerce_int_result(_, _, n), do: n

  defp collect_int_args(args) do
    any_float? = Enum.any?(args, &is_float/1)
    ints = Enum.map(args, &trunc_int/1)
    {ints, any_float?}
  end

  # ---- Type-checks shared by phase 6 primitives ------------------------------

  defp require_proper_list!(op, value) do
    if Value.list?(value), do: :ok, else: raise(Error, reason: {:improper_list, op, value})
  end

  defp require_procedure!(op, v) do
    if Value.procedure?(v), do: :ok, else: raise(Error, reason: {:type_error, op, "procedure", v})
  end

  defp require_vector!(_op, {:vector, _}), do: :ok

  defp require_vector!(op, other),
    do: raise(Error, reason: {:type_error, op, "vector", other})

  defp require_bytevector!(_op, {:bytevector, _}), do: :ok

  defp require_bytevector!(op, other),
    do: raise(Error, reason: {:type_error, op, "bytevector", other})

  defp require_string!(_op, s) when is_binary(s), do: :ok

  defp require_string!(op, other),
    do: raise(Error, reason: {:type_error, op, "string", other})

  defp require_char!(_op, {:char, cp}), do: cp

  defp require_char!(op, other),
    do: raise(Error, reason: {:type_error, op, "char", other})

  defp require_byte!(_op, n) when is_integer(n) and n >= 0 and n <= 255, do: n

  defp require_byte!(op, other),
    do: raise(Error, reason: {:byte_out_of_range, op, other})

  defp require_size!(op, k) do
    require_integer!(op, k)
    n = trunc_int(k)
    if n < 0, do: raise(Error, reason: {:invalid_size, op, k})
    n
  end

  defp require_index!(op, k, length) do
    require_integer!(op, k)
    i = trunc_int(k)

    if i < 0 or i >= length do
      raise(Error, reason: {:index_out_of_range, op, i, length})
    end

    i
  end

  defp require_bound!(op, k, lower, upper) do
    require_integer!(op, k)
    i = trunc_int(k)

    if i < lower or i > upper do
      raise(Error, reason: {:index_out_of_range, op, i, upper})
    end

    i
  end

  defp scheme_list_to_elixir!(op, list), do: do_scheme_list_to_elixir(op, list, [])
  defp do_scheme_list_to_elixir(_op, [], acc), do: Enum.reverse(acc)

  defp do_scheme_list_to_elixir(op, [h | t], acc),
    do: do_scheme_list_to_elixir(op, t, [h | acc])

  defp do_scheme_list_to_elixir(op, other, _acc),
    do: raise(Error, reason: {:improper_list, op, other})

  defp codepoint_to_utf8(cp) when is_integer(cp) and cp >= 0 and cp <= 0x10FFFF do
    <<cp::utf8>>
  rescue
    ArgumentError ->
      reraise Error, [reason: {:codepoint_out_of_range, "char", cp}], __STACKTRACE__
  end

  defp codepoint_to_utf8(cp),
    do: raise(Error, reason: {:codepoint_out_of_range, "char", cp})

  # Codepoint count of a UTF-8 binary. We do not use `String.length/1` since
  # that returns *grapheme* count, whereas r7rs strings are sequences of
  # Unicode scalars (codepoints).
  defp string_codepoint_length(s), do: count_codepoints(s, 0)
  defp count_codepoints(<<>>, n), do: n
  defp count_codepoints(<<_::utf8, rest::binary>>, n), do: count_codepoints(rest, n + 1)

  defp nth_codepoint(<<cp::utf8, _::binary>>, 0), do: {:ok, cp}
  defp nth_codepoint(<<_::utf8, rest::binary>>, n) when n > 0, do: nth_codepoint(rest, n - 1)
  defp nth_codepoint(_, _), do: :end

  defp skip_codepoints(s, 0), do: s
  defp skip_codepoints(<<_::utf8, rest::binary>>, n) when n > 0, do: skip_codepoints(rest, n - 1)
  defp skip_codepoints(<<>>, _n), do: :end

  # Single-pass slice: walks `s` once, returns `{byte_offset, byte_length}`
  # suitable for `:binary.part/3`. `stop` may be `nil` to mean "to end". The
  # codepoint length of `s` is computed only on the error path — the fast
  # path never traverses `s` more than once.
  defp string_byte_slice(s, start, stop, op) do
    start_i = require_start!(op, start, s)

    case skip_codepoints(s, start_i) do
      :end ->
        raise_index!(op, start_i, s)

      after_start ->
        slice_after_start(s, after_start, start_i, stop, op)
    end
  end

  defp slice_after_start(s, after_start, _start_i, nil, _op) do
    {byte_size(s) - byte_size(after_start), byte_size(after_start)}
  end

  defp slice_after_start(s, after_start, start_i, stop, op) do
    require_integer!(op, stop)
    stop_i = trunc_int(stop)
    if stop_i < start_i, do: raise_index!(op, stop_i, s)

    case skip_codepoints(after_start, stop_i - start_i) do
      :end ->
        raise_index!(op, stop_i, s)

      after_stop ->
        {byte_size(s) - byte_size(after_start), byte_size(after_start) - byte_size(after_stop)}
    end
  end

  # Single-pass codepoint slice: walks `s` once, returning the codepoints
  # in `[start, stop)`. Used by `string->list`. Same error-path policy as
  # `string_byte_slice/4`.
  defp slice_codepoints(s, start, stop, op) do
    start_i = require_start!(op, start, s)

    case skip_codepoints(s, start_i) do
      :end -> raise_index!(op, start_i, s)
      after_start -> collect_codepoints(s, after_start, start_i, stop, op)
    end
  end

  defp collect_codepoints(_s, after_start, _start_i, nil, _op),
    do: collect_to_end(after_start, [])

  defp collect_codepoints(s, after_start, start_i, stop, op) do
    require_integer!(op, stop)
    stop_i = trunc_int(stop)
    if stop_i < start_i, do: raise_index!(op, stop_i, s)
    collect_n(after_start, stop_i - start_i, [], op, stop_i, s)
  end

  defp collect_to_end(<<>>, acc), do: Enum.reverse(acc)
  defp collect_to_end(<<cp::utf8, rest::binary>>, acc), do: collect_to_end(rest, [cp | acc])

  defp collect_n(_s, 0, acc, _op, _stop, _orig), do: Enum.reverse(acc)

  defp collect_n(<<cp::utf8, rest::binary>>, n, acc, op, stop, orig) when n > 0,
    do: collect_n(rest, n - 1, [cp | acc], op, stop, orig)

  defp collect_n(<<>>, _n, _acc, op, stop, orig), do: raise_index!(op, stop, orig)

  defp require_start!(op, start, s) do
    require_integer!(op, start)
    i = trunc_int(start)
    if i < 0, do: raise_index!(op, i, s)
    i
  end

  defp raise_index!(op, i, s) do
    raise(Error, reason: {:index_out_of_range, op, i, string_codepoint_length(s)})
  end
end

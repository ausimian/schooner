defmodule Schooner.Primitives.Base do
  @moduledoc """
  Numeric core, type predicates, and boolean helpers from `(scheme base)`.

  Every binding here is registered as a `Schooner.Value.primitive/3` value
  in the standard environment. The evaluator already understands those
  via `Schooner.Eval.apply_proc/2` — this module just supplies the
  Elixir-side implementations.

  Exactness rules follow r7rs: integer-only inputs produce exact integer
  results where possible; any inexact (float) operand contaminates the
  whole expression. Operations that would step outside integer/float —
  rationals, complex, irrationals — raise `Schooner.Primitive.Error`
  rather than silently widening, because Schooner has no rational tower.
  """

  alias Schooner.Env
  alias Schooner.Primitive.Error
  alias Schooner.Value

  defguardp is_special(v)
            when is_tuple(v) and tuple_size(v) == 2 and elem(v, 0) == :float_special

  # ---------------------------------------------------------------------------
  # Public registration
  # ---------------------------------------------------------------------------

  @doc """
  Define every base primitive on `env`. Returns the same env (the global
  table is mutated in place — consistent with `Env.define/3`).
  """
  @spec register_into(Env.t()) :: Env.t()
  def register_into(%Env{} = env) do
    Enum.reduce(specs(), env, fn {name, arity, fun}, acc ->
      Env.define(acc, name, Value.primitive(name, arity, fun))
    end)
  end

  defp specs do
    arithmetic_specs() ++ comparison_specs() ++ predicate_specs() ++ boolean_specs()
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
      {"inexact->exact", 1, &inexact_to_exact/1}
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

  defp add_pair(a, b) when is_special(a) or is_special(b), do: special_add(a, b)
  defp add_pair(a, b) when is_float(a) or is_float(b), do: to_float(a) + to_float(b)
  defp add_pair(a, b), do: a + b

  defp sub_pair(a, b) when is_special(a) or is_special(b), do: special_add(a, negate(b))
  defp sub_pair(a, b) when is_float(a) or is_float(b), do: to_float(a) - to_float(b)
  defp sub_pair(a, b), do: a - b

  defp mul_pair(a, b) when is_special(a) or is_special(b), do: special_mul(a, b)
  defp mul_pair(a, b) when is_float(a) or is_float(b), do: to_float(a) * to_float(b)
  defp mul_pair(a, b), do: a * b

  defp negate({:float_special, :pos_inf}), do: {:float_special, :neg_inf}
  defp negate({:float_special, :neg_inf}), do: {:float_special, :pos_inf}
  defp negate({:float_special, :nan}), do: {:float_special, :nan}
  defp negate(n), do: -n

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

  defp divide_pair(_op, a, b) when is_integer(a) and is_integer(b) do
    cond do
      b == 0 -> raise Error, reason: {:division_by_zero, "/"}
      rem(a, b) == 0 -> div(a, b)
      true -> raise Error, reason: {:exact_division_not_integer, a, b}
    end
  end

  defp divide_pair(_op, a, b) when is_special(a) or is_special(b),
    do: special_divide(a, b)

  defp divide_pair(_op, a, b), do: do_float_divide(to_float(a), to_float(b))

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
    require_number!("abs", n)
    abs_special(n)
  end

  defp abs_special({:float_special, :neg_inf}), do: {:float_special, :pos_inf}
  defp abs_special({:float_special, k}), do: {:float_special, k}
  defp abs_special(n), do: abs(n)

  defp min_([first | rest]) do
    require_number!("min", first)

    Enum.reduce(rest, first, fn b, a ->
      require_number!("min", b)
      pick_min(a, b)
    end)
  end

  defp max_([first | rest]) do
    require_number!("max", first)

    Enum.reduce(rest, first, fn b, a ->
      require_number!("max", b)
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
  defp pick_min(a, b), do: min(a, b)

  defp pick_max({:float_special, :nan}, _), do: {:float_special, :nan}
  defp pick_max(_, {:float_special, :nan}), do: {:float_special, :nan}
  defp pick_max({:float_special, :pos_inf}, _), do: {:float_special, :pos_inf}
  defp pick_max(_, {:float_special, :pos_inf}), do: {:float_special, :pos_inf}
  defp pick_max({:float_special, :neg_inf}, b), do: to_float(b)
  defp pick_max(a, {:float_special, :neg_inf}), do: to_float(a)
  defp pick_max(a, b) when is_float(a) or is_float(b), do: max(to_float(a), to_float(b))
  defp pick_max(a, b), do: max(a, b)

  defp expt([base, exp]) do
    require_number!("expt", base)
    require_number!("expt", exp)
    do_expt(base, exp)
  end

  defp do_expt(base, exp) when is_integer(base) and is_integer(exp) and exp >= 0 do
    int_pow(base, exp)
  end

  defp do_expt(1, exp) when is_integer(exp), do: 1
  defp do_expt(-1, exp) when is_integer(exp) and rem(exp, 2) == 0, do: 1
  defp do_expt(-1, exp) when is_integer(exp), do: -1

  defp do_expt(base, exp) when is_integer(base) and is_integer(exp) do
    raise Error, reason: {:negative_exponent, base, exp}
  end

  defp do_expt(base, exp) when is_special(base) or is_special(exp),
    do: special_expt(base, exp)

  defp do_expt(base, exp), do: :math.pow(to_float(base), to_float(exp))

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

  defp int_pow(_b, 0), do: 1
  defp int_pow(b, 1), do: b

  defp int_pow(b, e) when rem(e, 2) == 0 do
    half = int_pow(b, div(e, 2))
    half * half
  end

  defp int_pow(b, e), do: b * int_pow(b, e - 1)

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

    cond do
      n == {:float_special, :pos_inf} -> {:float_special, :pos_inf}
      is_special(n) -> {:float_special, :nan}
      is_float(n) and n < 0.0 -> {:float_special, :nan}
      is_float(n) -> :math.sqrt(n)
      is_integer(n) and n >= 0 -> exact_isqrt_or_raise(n)
      true -> raise Error, reason: {:irrational, "sqrt", n}
    end
  end

  defp exact_isqrt_or_raise(n) do
    r = isqrt(n)
    if r * r == n, do: r, else: raise(Error, reason: {:irrational, "sqrt", n})
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

  defp exact_to_inexact([n]) do
    require_number!("exact->inexact", n)
    if is_special(n), do: n, else: to_float(n)
  end

  defp inexact_to_exact([n]) when is_integer(n), do: n

  defp inexact_to_exact([n]) when is_float(n) do
    if Value.integer?(n), do: trunc(n), else: raise(Error, reason: {:not_representable_exact, n})
  end

  defp inexact_to_exact([{:float_special, _} = n]) do
    raise Error, reason: {:not_representable_exact, n}
  end

  defp inexact_to_exact([other]) do
    raise Error, reason: {:type_error, "inexact->exact", "number", other}
  end

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

  defp cmp_eq(args), do: variadic_cmp("=", args, &num_eq/2)
  defp cmp_lt(args), do: variadic_cmp("<", args, &num_lt/2)
  defp cmp_gt(args), do: variadic_cmp(">", args, &num_gt/2)
  defp cmp_le(args), do: variadic_cmp("<=", args, &num_le/2)
  defp cmp_ge(args), do: variadic_cmp(">=", args, &num_ge/2)

  defp variadic_cmp(op, [first | rest], pair) do
    require_number!(op, first)
    Value.bool(check_pairs(rest, first, op, pair))
  end

  defp check_pairs([], _prev, _op, _pair), do: true

  defp check_pairs([b | rest], prev, op, pair) do
    require_number!(op, b)
    # IEEE-754: any comparison against NaN is "unordered" → false.
    cond do
      prev == {:float_special, :nan} -> false
      b == {:float_special, :nan} -> false
      pair.(prev, b) -> check_pairs(rest, b, op, pair)
      true -> false
    end
  end

  # `=` is numerical equality; `(= 1 1.0)` is true (only `eqv?` cares about exactness).
  defp num_eq(a, b) when is_special(a) or is_special(b), do: special_cmp_eq(a, b)
  defp num_eq(a, b) when is_float(a) or is_float(b), do: to_float(a) == to_float(b)
  defp num_eq(a, b), do: a == b

  defp num_lt(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) == :lt
  defp num_lt(a, b) when is_float(a) or is_float(b), do: to_float(a) < to_float(b)
  defp num_lt(a, b), do: a < b

  defp num_gt(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) == :gt
  defp num_gt(a, b) when is_float(a) or is_float(b), do: to_float(a) > to_float(b)
  defp num_gt(a, b), do: a > b

  defp num_le(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) in [:lt, :eq]
  defp num_le(a, b) when is_float(a) or is_float(b), do: to_float(a) <= to_float(b)
  defp num_le(a, b), do: a <= b

  defp num_ge(a, b) when is_special(a) or is_special(b), do: special_cmp(a, b) in [:gt, :eq]
  defp num_ge(a, b) when is_float(a) or is_float(b), do: to_float(a) >= to_float(b)
  defp num_ge(a, b), do: a >= b

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
      {"integer?", 1, &integer_p/1},
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
      {"symbol?", 1, &symbol_p/1},
      {"string?", 1, &string_p/1},
      {"char?", 1, &char_p/1},
      {"vector?", 1, &vector_p/1},
      {"bytevector?", 1, &bytevector_p/1},
      {"procedure?", 1, &procedure_p/1},
      {"eof-object?", 1, &eof_p/1}
    ]
  end

  defp number_p([v]), do: Value.bool(Value.number?(v))
  defp integer_p([v]), do: Value.bool(Value.integer?(v))
  defp exact_p([v]), do: Value.bool(Value.exact?(v))
  defp inexact_p([v]), do: Value.bool(Value.inexact?(v))
  defp boolean_p([v]), do: Value.bool(Value.boolean?(v))
  defp pair_p([v]), do: Value.bool(Value.pair?(v))
  defp null_p([v]), do: Value.bool(Value.null?(v))
  defp symbol_p([v]), do: Value.bool(Value.symbol?(v))
  defp string_p([v]), do: Value.bool(Value.string?(v))
  defp char_p([v]), do: Value.bool(Value.char?(v))
  defp vector_p([v]), do: Value.bool(Value.vector?(v))
  defp bytevector_p([v]), do: Value.bool(Value.bytevector?(v))
  defp procedure_p([v]), do: Value.bool(Value.procedure?(v))
  defp eof_p([v]), do: Value.bool(Value.eof?(v))

  defp zero_p([n]) do
    require_number!("zero?", n)
    Value.bool(not is_special(n) and n == 0)
  end

  defp positive_p([{:float_special, :pos_inf}]), do: Value.bool(true)
  defp positive_p([{:float_special, _}]), do: Value.bool(false)

  defp positive_p([n]) do
    require_number!("positive?", n)
    Value.bool(n > 0)
  end

  defp negative_p([{:float_special, :neg_inf}]), do: Value.bool(true)
  defp negative_p([{:float_special, _}]), do: Value.bool(false)

  defp negative_p([n]) do
    require_number!("negative?", n)
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
      {:bool, _} -> :ok
      other -> raise(Error, reason: {:type_error, "boolean=?", "boolean", other})
    end)

    Value.bool(Enum.all?(rest, &(&1 === first)))
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
  defp require_number!(_op, n) when is_special(n), do: :ok

  defp require_number!(op, other) do
    raise Error, reason: {:type_error, op, "number", other}
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
end

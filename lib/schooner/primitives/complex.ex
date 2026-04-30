defmodule Schooner.Primitives.Complex do
  @moduledoc """
  The `(scheme complex)` library: rectangular and polar constructors
  (`make-rectangular`, `make-polar`) and the four selectors
  (`real-part`, `imag-part`, `magnitude`, `angle`).

  Schooner represents a complex number as `{:complex, real, imag}`
  where each component is any non-complex number (integer, rational,
  finite float, or `:float_special` sentinel). `Schooner.Value.complex/2`
  collapses to the bare real component when `imag` is the exact integer
  `0`, so a tagged complex always carries a non-zero (or inexact)
  imaginary part. Real-only operations in `(scheme base)` reject
  complex inputs; the arithmetic primitives (`+`, `-`, `*`, `/`, `=`)
  and the transcendentals in `(scheme inexact)` accept them.

  Polar form `(make-polar magnitude angle)` is converted to
  rectangular on construction; Schooner does not retain the polar
  parametrisation. `magnitude` and `angle` reconstruct polar
  coordinates from the rectangular components on demand.
  """

  alias Schooner.Primitive.Error
  alias Schooner.Value

  defguardp is_special(v)
            when is_tuple(v) and tuple_size(v) == 2 and elem(v, 0) == :float_special

  defguardp is_rational(v)
            when is_tuple(v) and tuple_size(v) == 3 and elem(v, 0) == :rational

  defguardp is_real_number(v)
            when is_integer(v) or is_float(v) or is_rational(v) or is_special(v)

  @doc """
  Return every `(scheme complex)` primitive as `{name, arity, fun}`.
  Consumed by `Schooner.Library.Standard` to assemble the library.
  """
  @spec specs() :: [{binary(), non_neg_integer(), fun()}]
  def specs do
    [
      {"make-rectangular", 2, &make_rectangular/1},
      {"make-polar", 2, &make_polar/1},
      {"real-part", 1, &real_part/1},
      {"imag-part", 1, &imag_part/1},
      {"magnitude", 1, &magnitude/1},
      {"angle", 1, &angle/1}
    ]
  end

  defp make_rectangular([r, i]) do
    require_real!("make-rectangular", r)
    require_real!("make-rectangular", i)
    Value.complex(r, i)
  end

  # `magnitude * (cos angle + i sin angle)`. Both components are
  # forced to floats — polar form intrinsically introduces
  # transcendentals so the result is inexact even for rational inputs.
  defp make_polar([m, a]) do
    mf = require_finite_real!("make-polar", m)
    af = require_finite_real!("make-polar", a)
    Value.complex(mf * :math.cos(af), mf * :math.sin(af))
  end

  defp real_part([{:complex, r, _}]), do: r
  defp real_part([n]) when is_real_number(n), do: n
  defp real_part([other]), do: raise_type("real-part", other)

  # Imag part of a real takes its exactness from the operand: an exact
  # real has imag 0, an inexact real has imag 0.0. Matches r7rs §6.2.6
  # so `(eqv? 1 1)` ⟹ #t but `(eqv? 1.0 (real-part 1.0))` keeps the
  # inexact contagion when `imag-part` is later applied to the same.
  defp imag_part([{:complex, _, i}]), do: i
  defp imag_part([n]) when is_integer(n) or is_rational(n), do: 0
  defp imag_part([n]) when is_float(n), do: 0.0
  defp imag_part([{:float_special, _}]), do: 0.0
  defp imag_part([other]), do: raise_type("imag-part", other)

  defp magnitude([{:complex, r, i}]), do: complex_magnitude(r, i)
  defp magnitude([n]) when is_real_number(n), do: real_magnitude(n)
  defp magnitude([other]), do: raise_type("magnitude", other)

  defp angle([{:complex, r, i}]), do: complex_angle(r, i)
  defp angle([n]) when is_real_number(n), do: real_angle(n)
  defp angle([other]), do: raise_type("angle", other)

  # |a + bi| = sqrt(a^2 + b^2). Always inexact: the magnitude of a
  # rational complex is irrational in general (|1+i| = sqrt 2) and
  # Schooner does not promote outside the rationals.
  defp complex_magnitude(r, i) do
    cond do
      special_nan?(r) or special_nan?(i) ->
        {:float_special, :nan}

      special_inf?(r) or special_inf?(i) ->
        {:float_special, :pos_inf}

      true ->
        rf = real_to_float(r)
        if_ = real_to_float(i)
        :math.sqrt(rf * rf + if_ * if_)
    end
  end

  # arg(a + bi) = atan2(b, a). Erlang's atan2 cannot represent IEEE
  # infinity inputs, so the special quadrants are dispatched by hand
  # before delegating to `:math.atan2/2` for the finite cases.
  defp complex_angle(r, i) do
    cond do
      special_nan?(r) or special_nan?(i) ->
        {:float_special, :nan}

      special_inf?(r) or special_inf?(i) ->
        special_atan2(i, r)

      true ->
        :math.atan2(real_to_float(i), real_to_float(r))
    end
  end

  defp real_magnitude({:float_special, :neg_inf}), do: {:float_special, :pos_inf}
  defp real_magnitude({:float_special, k}), do: {:float_special, k}
  defp real_magnitude({:rational, n, d}), do: {:rational, abs(n), d}
  defp real_magnitude(n), do: abs(n)

  # Principal-value angle of a real: 0 for non-negatives, π for
  # negatives. Inexact operands give an inexact result so the
  # exactness of `(angle x)` tracks `(angle (make-rectangular x 0))`.
  defp real_angle({:float_special, :nan}), do: {:float_special, :nan}
  defp real_angle({:float_special, :pos_inf}), do: 0.0
  defp real_angle({:float_special, :neg_inf}), do: :math.pi()
  defp real_angle(n) when is_integer(n) and n >= 0, do: 0
  defp real_angle(n) when is_integer(n), do: :math.pi()
  defp real_angle({:rational, n, _}) when n >= 0, do: 0
  defp real_angle({:rational, _, _}), do: :math.pi()
  defp real_angle(n) when is_float(n) and n >= 0.0, do: 0.0
  defp real_angle(n) when is_float(n), do: :math.pi()

  # IEEE-754 atan2 special quadrants. `i` is y, `r` is x.
  defp special_atan2({:float_special, :pos_inf}, {:float_special, :pos_inf}), do: :math.pi() / 4.0

  defp special_atan2({:float_special, :pos_inf}, {:float_special, :neg_inf}),
    do: 3.0 * :math.pi() / 4.0

  defp special_atan2({:float_special, :neg_inf}, {:float_special, :pos_inf}),
    do: -:math.pi() / 4.0

  defp special_atan2({:float_special, :neg_inf}, {:float_special, :neg_inf}),
    do: -3.0 * :math.pi() / 4.0

  defp special_atan2({:float_special, :pos_inf}, _), do: :math.pi() / 2.0
  defp special_atan2({:float_special, :neg_inf}, _), do: -:math.pi() / 2.0

  defp special_atan2(y, {:float_special, :pos_inf}) when is_real_number(y),
    do: copy_sign(0.0, y)

  defp special_atan2(y, {:float_special, :neg_inf}) when is_real_number(y),
    do: copy_sign(:math.pi(), y)

  defp copy_sign(value, y), do: if(real_negative?(y), do: -value, else: value)

  defp real_negative?(n) when is_integer(n), do: n < 0
  defp real_negative?({:rational, n, _}), do: n < 0
  defp real_negative?(n) when is_float(n), do: n < 0.0

  defp special_inf?({:float_special, k}) when k in [:pos_inf, :neg_inf], do: true
  defp special_inf?(_), do: false

  defp special_nan?({:float_special, :nan}), do: true
  defp special_nan?(_), do: false

  defp real_to_float(n) when is_integer(n), do: n * 1.0
  defp real_to_float(n) when is_float(n), do: n
  defp real_to_float({:rational, n, d}), do: n / d

  defp require_real!(_op, n) when is_real_number(n), do: :ok
  defp require_real!(op, other), do: raise_type(op, other)

  defp require_finite_real!(_op, n) when is_integer(n), do: n * 1.0
  defp require_finite_real!(_op, n) when is_float(n), do: n
  defp require_finite_real!(_op, {:rational, n, d}), do: n / d

  defp require_finite_real!(op, {:float_special, _} = v),
    do: raise(Error, reason: {:type_error, op, "finite real number", v})

  defp require_finite_real!(op, other), do: raise_type(op, other)

  defp raise_type(op, other), do: raise(Error, reason: {:type_error, op, "real number", other})
end

defmodule Schooner.Value do
  @moduledoc """
  Term representation of Scheme values.

  Where the BEAM already distinguishes types cleanly we use them
  directly: booleans, the empty list, cons cells, integers, floats, and
  strings (binaries) all live as their native Elixir form. Where types
  would otherwise alias — symbols vs strings vs bytevectors (all binaries),
  characters vs integers, vectors vs records vs closures (all tuples) —
  the colliding side is tagged.

  ## Representations

    * Booleans  — bare Elixir `true` / `false`. Only `false` is
      Scheme-falsy. Every other value is truthy, including `:null` and `0`.
    * Empty list — bare Elixir `[]`
    * Pair — Elixir cons cell `[car | cdr]`. Improper Scheme pairs are
      improper Erlang lists (`[a | b]` where `b` is not a list).
    * Symbol — `{:sym, binary}` (binaries, not atoms; user-supplied
      identifiers must not exhaust the BEAM atom table)
    * String — bare Elixir binary. Disambiguated from symbol/bytevector
      because those remain tagged.
    * Character — `{:char, codepoint}`
    * Exact integer — bare Elixir integer
    * Exact rational — `{:rational, numerator, denominator}`. Always
      reduced (`gcd(num, denom) == 1`), denominator strictly greater
      than 1, sign carried on the numerator. A rational whose
      denominator would reduce to 1 is collapsed to its bare integer
      form by `rational/2`, so the integer/rational split is total —
      no Schooner value is both.
    * Inexact real — bare Elixir float
    * Non-finite inexact — `{:float_special, :pos_inf | :neg_inf | :nan}`
      (BEAM floats cannot represent these; tagged forms carry IEEE-754
      semantics through arithmetic and comparison without smuggling
      forbidden bit patterns into Elixir floats.)
    * Complex — `{:complex, real, imag}` where each component is any
      non-complex number (integer, rational, float, or float_special).
      `complex/2` collapses to the bare real component when `imag === 0`
      so the real/complex split is total — any value with a complex tag
      has a non-zero (or inexact) imaginary part. Polar literals are
      converted to rectangular form on read.
    * Vector — `{:vector, tuple}`
    * Bytevector — `{:bytevector, binary}`
    * Closure — `{:closure, params, body, env, name_or_nil}`
    * Primitive — `{:primitive, name, arity, fun}`
    * Record — `{:record, type_id, fields_tuple}`
    * Record type identity — `{:record_type, name, unique_int}` —
      embedded as a literal in the bindings produced by
      `define-record-type`. Self-evaluating; compared with `===` so
      two definitions with the same record name in different
      lexical scopes produce distinct identities.
    * Error object — `{:error_obj, kind, message, irritants}` where
      `kind` is `:user | :read | :file`, `message` is a Scheme string
      value, and `irritants` is an Elixir list of Scheme values
      (rendered as a Scheme list by the accessor). Constructed by
      `(error msg irritant ...)` and reachable via `error?`,
      `error-object?`, `read-error?`, `file-error?`.
    * Parameter — `{:parameter, id, init, converter}`. `id` is a
      process-monotonic unique integer used as the lookup key in the
      `Schooner.Eval.ParameterState` dynamic-binding stack. `init` is
      the post-converter initial value (returned when no
      `parameterize` is currently shadowing the parameter).
      `converter` is either `nil` or a Scheme procedure applied to
      every value installed for the parameter (initial *or* via
      `parameterize`). Parameters are procedure values: calling one
      with zero arguments returns the current value.
    * EOF — `:eof`
    * Unspecified — `:unspecified`
  """

  @type bool_v :: boolean()
  @type pair_v :: nonempty_maybe_improper_list(t(), t())
  @type sym_v :: {:sym, binary()}
  @type string_v :: binary()
  @type char_v :: {:char, non_neg_integer()}
  @type vector_v :: {:vector, tuple()}
  @type bytevector_v :: {:bytevector, binary()}
  @type closure_v :: {:closure, term(), term(), term(), binary() | nil}
  @type primitive_v :: {:primitive, binary(), arity_spec(), (list() -> t())}
  @type record_v :: {:record, term(), tuple()}
  @type record_type_id_v :: {:record_type, binary(), pos_integer()}
  @type rational_v :: {:rational, integer(), pos_integer()}
  @type float_special_v :: {:float_special, :pos_inf | :neg_inf | :nan}
  @type real_v :: integer() | rational_v() | float() | float_special_v()
  @type complex_v :: {:complex, real_v(), real_v()}
  @type error_kind :: :user | :read | :file
  @type error_obj_v :: {:error_obj, error_kind(), t(), [t()]}
  @type promise_v :: {:promise, :forced, t()} | {:promise, :lazy, term()}
  @type parameter_v :: {:parameter, integer(), t(), t() | nil}
  @type arity_spec ::
          non_neg_integer()
          | {:at_least, non_neg_integer()}
          | {:between, non_neg_integer(), non_neg_integer()}

  @type t ::
          bool_v()
          | []
          | pair_v()
          | sym_v()
          | string_v()
          | char_v()
          | integer()
          | rational_v()
          | float()
          | float_special_v()
          | complex_v()
          | vector_v()
          | bytevector_v()
          | closure_v()
          | primitive_v()
          | record_v()
          | record_type_id_v()
          | error_obj_v()
          | promise_v()
          | parameter_v()
          | :eof
          | :unspecified

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @spec bool(boolean()) :: bool_v()
  def bool(true), do: true
  def bool(false), do: false

  @spec pair(t(), t()) :: pair_v()
  def pair(car, cdr), do: [car | cdr]

  @spec symbol(binary()) :: sym_v()
  def symbol(name) when is_binary(name), do: {:sym, name}

  @spec string(binary()) :: string_v()
  def string(s) when is_binary(s), do: s

  @spec char(non_neg_integer()) :: char_v()
  def char(cp) when is_integer(cp) and cp >= 0, do: {:char, cp}

  @doc """
  Build a normalised exact rational. Result is always reduced (numerator
  and denominator share no common factor), the sign is carried on the
  numerator, and a denominator of 1 collapses to a bare integer so
  integer-valued rationals are never tagged.

  Raises `ArithmeticError` on a zero denominator — callers in primitive
  paths should detect division-by-zero earlier and surface a structured
  Scheme-level error instead.
  """
  @spec rational(integer(), integer()) :: integer() | rational_v()
  def rational(_num, 0), do: raise(ArithmeticError, "zero denominator in rational")
  def rational(0, _den), do: 0

  def rational(num, den) when is_integer(num) and is_integer(den) do
    g = Integer.gcd(num, den)
    {n, d} = if den > 0, do: {div(num, g), div(den, g)}, else: {-div(num, g), -div(den, g)}
    if d == 1, do: n, else: {:rational, n, d}
  end

  @doc """
  Build a rectangular complex value. `real` and `imag` must be
  non-complex numbers (integers, rationals, floats, or `:float_special`
  sentinels). When `imag` is the exact integer `0` the result collapses
  to `real`, keeping the real / complex split total: a value tagged
  `:complex` always carries a non-zero (or inexact) imaginary part.

  Inexact zeros (`+0.0`, `-0.0`) do **not** collapse — `(make-rectangular
  1.0 0.0)` is `1.0+0.0i`, distinct from `1.0`. Per r7rs §6.2.6 only an
  exactly zero imaginary part makes the whole number `real?`.
  """
  @spec complex(real_v(), real_v()) :: real_v() | complex_v()
  def complex(real, 0), do: real
  def complex(real, imag), do: {:complex, real, imag}

  @spec vector([t()]) :: vector_v()
  def vector(items) when is_list(items), do: {:vector, List.to_tuple(items)}

  @spec bytevector([byte()] | binary()) :: bytevector_v()
  def bytevector(bytes) when is_list(bytes), do: {:bytevector, :erlang.list_to_binary(bytes)}
  def bytevector(bin) when is_binary(bin), do: {:bytevector, bin}

  @spec closure(term(), term(), term(), binary() | nil) :: closure_v()
  def closure(params, body, env, name \\ nil), do: {:closure, params, body, env, name}

  @spec primitive(binary(), arity_spec(), (list() -> t())) :: primitive_v()
  def primitive(name, arity, fun) when is_binary(name) and is_function(fun, 1) do
    {:primitive, name, arity, fun}
  end

  @spec record(term(), tuple()) :: record_v()
  def record(type_id, fields) when is_tuple(fields), do: {:record, type_id, fields}

  @spec error_object(error_kind(), t(), [t()]) :: error_obj_v()
  def error_object(kind, message, irritants)
      when kind in [:user, :read, :file] and is_list(irritants) do
    {:error_obj, kind, message, irritants}
  end

  @doc """
  Build a parameter value with a fresh id. `init` is the
  already-converted initial value. `converter` is either `nil` (when
  `make-parameter` was called without one) or a Scheme procedure
  applied to every value installed for the parameter via
  `parameterize`.
  """
  @spec parameter(t(), t() | nil) :: parameter_v()
  def parameter(init, converter) do
    {:parameter, :erlang.unique_integer([:monotonic]), init, converter}
  end

  @doc """
  Wrap `value` as an already-forced (eager) promise. Forcing it
  returns `value` without invoking any procedure — the same shape as
  r7rs's `(make-promise obj)`.
  """
  @spec eager_promise(t()) :: promise_v()
  def eager_promise(value), do: {:promise, :forced, value}

  @doc """
  Wrap `thunk` (a zero-arg Scheme procedure) as a lazy promise.
  `force` applies the thunk and, if the result is itself a promise,
  keeps unwrapping iteratively. Schooner promises do not memoise —
  no mutation is available, so repeated forcing re-evaluates.
  """
  @spec lazy_promise(term()) :: promise_v()
  def lazy_promise(thunk), do: {:promise, :lazy, thunk}

  @doc """
  Build a Scheme list (proper, null-terminated) from an Elixir list.

  After the pair/null untagging this is the identity on Elixir lists.
  Kept as a named constructor so call sites stay self-documenting and
  the seam survives any future representation change.
  """
  @spec list([t()]) :: t()
  def list(items) when is_list(items), do: items

  @doc """
  Build an improper Scheme list. The last argument becomes the cdr of the
  innermost pair.
  """
  @spec improper_list([t(), ...], t()) :: t()
  def improper_list([only], tail), do: [only | tail]
  def improper_list([h | t], tail), do: [h | improper_list(t, tail)]

  @doc """
  Convert a proper Scheme list (cons cells terminated by `[]`) into
  an Elixir list. Raises `ArgumentError` on an improper list — the
  inverse of `list/1`.
  """
  @spec to_list(t()) :: [t()]
  def to_list([]), do: []
  def to_list([h | t]) when is_list(t), do: [h | to_list(t)]

  def to_list(other),
    do: raise(ArgumentError, "expected proper Scheme list, got #{inspect(other)}")

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  @spec boolean?(term()) :: boolean()
  def boolean?(true), do: true
  def boolean?(false), do: true
  def boolean?(_), do: false

  @spec null?(term()) :: boolean()
  def null?([]), do: true
  def null?(_), do: false

  @spec pair?(term()) :: boolean()
  def pair?([_ | _]), do: true
  def pair?(_), do: false

  @spec symbol?(term()) :: boolean()
  def symbol?({:sym, _}), do: true
  def symbol?(_), do: false

  @spec string?(term()) :: boolean()
  def string?(s) when is_binary(s), do: true
  def string?(_), do: false

  @spec char?(term()) :: boolean()
  def char?({:char, _}), do: true
  def char?(_), do: false

  @spec vector?(term()) :: boolean()
  def vector?({:vector, _}), do: true
  def vector?(_), do: false

  @spec bytevector?(term()) :: boolean()
  def bytevector?({:bytevector, _}), do: true
  def bytevector?(_), do: false

  @spec procedure?(term()) :: boolean()
  def procedure?({:closure, _, _, _, _}), do: true
  def procedure?({:primitive, _, _, _}), do: true
  def procedure?({:parameter, _, _, _}), do: true
  def procedure?(_), do: false

  @spec parameter?(term()) :: boolean()
  def parameter?({:parameter, _, _, _}), do: true
  def parameter?(_), do: false

  @spec record?(term()) :: boolean()
  def record?({:record, _, _}), do: true
  def record?(_), do: false

  @spec error_object?(term()) :: boolean()
  def error_object?({:error_obj, _, _, _}), do: true
  def error_object?(_), do: false

  @spec error_kind?(term(), error_kind()) :: boolean()
  def error_kind?({:error_obj, kind, _, _}, kind), do: true
  def error_kind?(_, _), do: false

  @spec eof?(term()) :: boolean()
  def eof?(:eof), do: true
  def eof?(_), do: false

  @doc """
  Scheme `list?` — true for `[]` and proper (null-terminated) cons chains;
  false for improper lists, atoms, and anything that ends in a non-pair non-null.
  """
  @spec list?(term()) :: boolean()
  def list?([]), do: true
  def list?([_ | t]), do: list?(t)
  def list?(_), do: false

  @spec unspecified?(term()) :: boolean()
  def unspecified?(:unspecified), do: true
  def unspecified?(_), do: false

  @spec number?(term()) :: boolean()
  def number?(n) when is_integer(n) or is_float(n), do: true
  def number?({:rational, _, _}), do: true
  def number?({:float_special, k}) when k in [:pos_inf, :neg_inf, :nan], do: true
  def number?({:complex, _, _}), do: true
  def number?(_), do: false

  @doc """
  Scheme `complex?`. Schooner ships the full numeric tower from
  integers up through complex, so `complex?` and `number?` agree.
  """
  @spec complex?(term()) :: boolean()
  def complex?(v), do: number?(v)

  @doc """
  Scheme `real?`. Real numbers are anything outside the `:complex` tag —
  integers, rationals, finite floats, and the non-finite specials. A
  complex value whose imaginary part is exact zero collapses to its
  real part on construction, so a tagged complex always has a non-zero
  (or inexact) imaginary part and is therefore not real.
  """
  @spec real?(term()) :: boolean()
  def real?({:complex, _, _}), do: false
  def real?(v), do: number?(v)

  @spec integer?(term()) :: boolean()
  def integer?(n) when is_integer(n), do: true
  def integer?(n) when is_float(n), do: integer_valued_float?(n)
  def integer?(_), do: false

  defp integer_valued_float?(f) do
    trunc(f) == f
  rescue
    ArgumentError -> false
  end

  @doc """
  Scheme `rational?`. True for exact integers, exact rationals, and any
  finite inexact real (since every finite IEEE-754 double has an exact
  rational representation). False for the non-finite specials
  (`+inf.0`, `-inf.0`, `+nan.0`) and non-numeric values.
  """
  @spec rational?(term()) :: boolean()
  def rational?(n) when is_integer(n), do: true
  def rational?({:rational, _, _}), do: true
  def rational?(n) when is_float(n), do: true
  def rational?(_), do: false

  @spec exact?(term()) :: boolean()
  def exact?(n) when is_integer(n), do: true
  def exact?({:rational, _, _}), do: true
  def exact?({:complex, r, i}), do: exact?(r) and exact?(i)
  def exact?(_), do: false

  @spec inexact?(term()) :: boolean()
  def inexact?(n) when is_float(n), do: true
  def inexact?({:float_special, k}) when k in [:pos_inf, :neg_inf, :nan], do: true
  def inexact?({:complex, r, i}), do: inexact?(r) or inexact?(i)
  def inexact?(_), do: false

  @spec float_special?(term()) :: boolean()
  def float_special?({:float_special, k}) when k in [:pos_inf, :neg_inf, :nan], do: true
  def float_special?(_), do: false

  @spec promise?(term()) :: boolean()
  def promise?({:promise, kind, _}) when kind in [:forced, :lazy], do: true
  def promise?(_), do: false

  @doc """
  Scheme truthiness: only `false` is false; every other value is
  truthy, including `:null`, `0`, and the empty string.
  """
  @spec truthy?(t()) :: boolean()
  def truthy?(false), do: false
  def truthy?(_), do: true

  # ---------------------------------------------------------------------------
  # Equality
  # ---------------------------------------------------------------------------

  @doc """
  Scheme `eq?`. Identical to `eqv?` for Schooner — r7rs permits an
  implementation to collapse the two so long as the stronger discriminations
  `eq?` is allowed to draw (distinct heap copies of structurally-equal
  aggregates) are also drawn by `eqv?`. They are: see `eqv?/2` below.
  """
  @spec eq?(t(), t()) :: boolean()
  def eq?(a, b), do: eqv?(a, b)

  @doc """
  Scheme `eqv?`. Atomic values (numbers, characters, symbols, booleans,
  `()`, `:eof`, `:unspecified`) compare by content, with exactness preserved
  for numbers — `(eqv? 1 1.0)` is `#f`. Aggregates (pairs, vectors, strings,
  bytevectors, records, procedures, promises, parameters, error objects)
  compare by physical identity via `:erts_debug.same/2` — two
  structurally-equal aggregates built independently are *not* `eqv?`. This
  is r7rs's "denote different locations in the store" semantics, recovered
  for an immutable value model by leaning on the BEAM's heap layout instead
  of explicit identity tags.

  `:erts_debug.same/2` is an unofficial OTP BIF; it has been stable across
  many releases and is used by the Erlang/OTP test suite. Compiler / loader
  literal sharing means two source-level literals like `'(1 2)` written in
  the same module *may* be deduplicated and report `same` — r7rs explicitly
  permits constants to be shared, so this is allowed but worth pinning with
  a test if relevant to caller behaviour.
  """
  @spec eqv?(t(), t()) :: boolean()
  # IEEE-754: NaN is never equal to anything, including another NaN.
  def eqv?({:float_special, :nan}, _), do: false
  def eqv?(_, {:float_special, :nan}), do: false
  def eqv?({:complex, r1, i1}, {:complex, r2, i2}), do: eqv?(r1, r2) and eqv?(i1, i2)
  def eqv?(a, b), do: :erts_debug.same(a, b) or (atomic?(a) and a === b)

  # Values for which r7rs requires `eqv?` (and therefore `eq?`) to compare
  # by content rather than by location. Bare integers / floats / atoms are
  # immediates on the BEAM and already collapse under `:erts_debug.same/2`,
  # but listing them here keeps the predicate self-contained against future
  # boxing changes and means callers can rely on it independently.
  defp atomic?(n) when is_integer(n) or is_float(n), do: true
  defp atomic?({:rational, _, _}), do: true
  defp atomic?({:float_special, _}), do: true
  defp atomic?({:complex, _, _}), do: true
  defp atomic?({:char, _}), do: true
  defp atomic?({:sym, _}), do: true
  defp atomic?(true), do: true
  defp atomic?(false), do: true
  defp atomic?([]), do: true
  defp atomic?(:eof), do: true
  defp atomic?(:unspecified), do: true
  defp atomic?(_), do: false

  @doc """
  Scheme `equal?`. Recurses structurally into pairs, vectors, bytevectors,
  strings, and records. For everything else it falls through to `eqv?`.
  """
  @spec equal?(t(), t()) :: boolean()
  # IEEE-754: NaN is never equal to anything, including another NaN.
  def equal?({:float_special, :nan}, _), do: false
  def equal?(_, {:float_special, :nan}), do: false
  def equal?(a, a), do: true
  def equal?([h1 | t1], [h2 | t2]), do: equal?(h1, h2) and equal?(t1, t2)
  def equal?({:vector, t1}, {:vector, t2}), do: equal_tuples?(t1, t2)
  def equal?({:bytevector, b1}, {:bytevector, b2}), do: b1 == b2

  def equal?({:record, id1, f1}, {:record, id2, f2}) do
    id1 === id2 and equal_tuples?(f1, f2)
  end

  def equal?(_, _), do: false

  defp equal_tuples?(t1, t2) when tuple_size(t1) != tuple_size(t2), do: false

  defp equal_tuples?(t1, t2) do
    Enum.all?(0..(tuple_size(t1) - 1), fn i ->
      equal?(elem(t1, i), elem(t2, i))
    end)
  end

  # ---------------------------------------------------------------------------
  # write / display
  # ---------------------------------------------------------------------------

  @doc """
  Machine-readable rendering. Strings are wrapped in quotes, characters as
  `#\\name` or `#\\x..`, and unprintable characters are escaped.
  """
  @spec write(t()) :: binary()
  def write(value), do: IO.iodata_to_binary(write_iodata(value))

  @doc """
  Human-readable rendering. Strings render without quotes and characters as
  their literal codepoint. Aggregates recurse using `display`-style rendering
  for their elements.
  """
  @spec display(t()) :: binary()
  def display(value), do: IO.iodata_to_binary(display_iodata(value))

  @spec write_iodata(t()) :: iodata()
  def write_iodata(value), do: render(value, :write)

  @spec display_iodata(t()) :: iodata()
  def display_iodata(value), do: render(value, :display)

  defp render(true, _), do: "#t"
  defp render(false, _), do: "#f"
  defp render([], _), do: "()"
  defp render(:eof, _), do: "#<eof>"
  defp render(:unspecified, _), do: "#<unspecified>"
  defp render({:sym, name}, _), do: render_symbol(name)
  defp render(s, :write) when is_binary(s), do: [?", escape_string(s), ?"]
  defp render(s, :display) when is_binary(s), do: s
  defp render({:char, cp}, :write), do: render_char_write(cp)
  defp render({:char, cp}, :display), do: <<cp::utf8>>
  defp render({:bytevector, b}, _), do: render_bytevector(b)
  defp render({:vector, t}, mode), do: render_vector(t, mode)
  defp render([_ | _] = p, mode), do: render_pair(p, mode)
  defp render({:closure, _, _, _, name}, _), do: render_closure(name)
  defp render({:primitive, name, _, _}, _), do: ["#<primitive ", name, ">"]
  defp render({:record, {:record_type, name, _}, _}, _), do: ["#<record ", name, ">"]
  defp render({:record, type_id, _}, _), do: ["#<record ", inspect(type_id), ">"]
  defp render({:promise, _, _}, _), do: "#<promise>"
  defp render({:parameter, _, _, _}, _), do: "#<parameter>"

  defp render({:error_obj, kind, message, irritants}, mode),
    do: render_error(kind, message, irritants, mode)

  defp render({:float_special, :pos_inf}, _), do: "+inf.0"
  defp render({:float_special, :neg_inf}, _), do: "-inf.0"
  defp render({:float_special, :nan}, _), do: "+nan.0"
  defp render({:rational, n, d}, _), do: [Integer.to_string(n), ?/, Integer.to_string(d)]
  defp render({:complex, r, i}, mode), do: render_complex(r, i, mode)
  defp render(n, _) when is_integer(n), do: Integer.to_string(n)
  defp render(n, _) when is_float(n), do: render_float(n)

  defp render_pair(pair, mode) do
    {items, tail} = collect_pair(pair, [])

    head = items |> Enum.reverse() |> Enum.map(&render(&1, mode)) |> Enum.intersperse(?\s)

    case tail do
      [] -> [?(, head, ?)]
      _ -> [?(, head, " . ", render(tail, mode), ?)]
    end
  end

  defp collect_pair([car | cdr], acc), do: collect_pair(cdr, [car | acc])
  defp collect_pair(other, acc), do: {acc, other}

  defp render_vector(t, mode) do
    body =
      0..(tuple_size(t) - 1)//1
      |> Enum.map(&render(elem(t, &1), mode))
      |> Enum.intersperse(?\s)

    ["#(", body, ?)]
  end

  defp render_bytevector(b) do
    body =
      b
      |> :erlang.binary_to_list()
      |> Enum.map(&Integer.to_string/1)
      |> Enum.intersperse(?\s)

    ["#u8(", body, ?)]
  end

  defp render_closure(nil), do: "#<procedure>"
  defp render_closure(name) when is_binary(name), do: ["#<procedure ", name, ">"]

  defp render_error(kind, message, irritants, mode) do
    msg = render(message, mode)
    irrs = irritants |> Enum.map(&render(&1, mode)) |> Enum.intersperse(?\s)
    tail = if irritants == [], do: [], else: [" ", irrs]
    ["#<", error_kind_label(kind), " ", msg, tail, ">"]
  end

  defp error_kind_label(:user), do: "error"
  defp error_kind_label(:read), do: "read-error"
  defp error_kind_label(:file), do: "file-error"

  defp render_float(f) do
    s = :erlang.float_to_binary(f, [:short])
    if String.contains?(s, ".") or String.contains?(s, "e"), do: s, else: s <> ".0"
  end

  # Rectangular print form. The imaginary half always carries an
  # explicit sign so the literal round-trips through the reader: unit
  # imaginaries collapse to `+i` / `-i`, otherwise prepend `+` when the
  # imag part's own rendering does not already start with one. An exact
  # integer-zero real prints as just the imaginary half (Chibi style).
  defp render_complex(0, 1, _mode), do: "+i"
  defp render_complex(0, -1, _mode), do: "-i"
  defp render_complex(0, i, mode), do: [render_signed_imag(i, mode), ?i]
  defp render_complex(r, 1, mode), do: [render(r, mode), "+i"]
  defp render_complex(r, -1, mode), do: [render(r, mode), "-i"]
  defp render_complex(r, i, mode), do: [render(r, mode), render_signed_imag(i, mode), ?i]

  defp render_signed_imag(i, mode) do
    rendered = IO.iodata_to_binary(render(i, mode))

    case rendered do
      <<?+, _::binary>> -> rendered
      <<?-, _::binary>> -> rendered
      _ -> [?+, rendered]
    end
  end

  # ---- string escaping --------------------------------------------------------

  defp escape_string(s), do: for(<<cp::utf8 <- s>>, do: escape_char_in_string(cp))

  defp escape_char_in_string(?"), do: "\\\""
  defp escape_char_in_string(?\\), do: "\\\\"
  defp escape_char_in_string(?\n), do: "\\n"
  defp escape_char_in_string(?\r), do: "\\r"
  defp escape_char_in_string(?\t), do: "\\t"
  defp escape_char_in_string(?\b), do: "\\b"

  defp escape_char_in_string(cp) when cp < 0x20 or cp == 0x7F do
    "\\x" <> Integer.to_string(cp, 16) <> ";"
  end

  defp escape_char_in_string(cp), do: <<cp::utf8>>

  # ---- character names --------------------------------------------------------

  @char_names %{
    0 => "null",
    7 => "alarm",
    8 => "backspace",
    9 => "tab",
    10 => "newline",
    13 => "return",
    27 => "escape",
    32 => "space",
    127 => "delete"
  }

  defp render_char_write(cp) do
    case Map.fetch(@char_names, cp) do
      {:ok, name} -> ["#\\", name]
      :error when cp >= 0x20 and cp < 0x7F -> ["#\\", <<cp>>]
      :error -> ["#\\x", Integer.to_string(cp, 16)]
    end
  end

  # ---- symbol rendering -------------------------------------------------------

  @bar_unsafe [?(, ?), ?[, ?], ?{, ?}, ?\\, ?", ?', ?`, ?,, ?;, ?|, ?#]

  defp render_symbol(""), do: "||"

  defp render_symbol(name) do
    if needs_bar_quoting?(name), do: bar_quote(name), else: name
  end

  defp needs_bar_quoting?(<<>>), do: true

  defp needs_bar_quoting?(name) do
    case :binary.first(name) do
      cp when cp in ?0..?9 -> true
      _ -> Enum.any?(:erlang.binary_to_list(name), &symbol_char_unsafe?/1)
    end
  end

  defp symbol_char_unsafe?(cp) when cp <= 0x20, do: true
  defp symbol_char_unsafe?(cp) when cp == 0x7F, do: true
  defp symbol_char_unsafe?(cp), do: cp in @bar_unsafe

  defp bar_quote(name) do
    body = for <<cp::utf8 <- name>>, do: escape_char_in_symbol(cp)
    [?|, body, ?|]
  end

  defp escape_char_in_symbol(?|), do: "\\|"
  defp escape_char_in_symbol(?\\), do: "\\\\"
  defp escape_char_in_symbol(cp), do: <<cp::utf8>>
end

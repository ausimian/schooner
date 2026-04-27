defmodule Schooner.Value do
  @moduledoc """
  Tagged-term representation of Scheme values.

  All Scheme values map to Elixir terms with deliberate tags so that types
  which would otherwise alias on the BEAM remain distinguishable: Scheme
  `#f` from `'()` from unspecified, strings from bytevectors, symbols from
  strings, exact integers from inexact reals.

  ## Representations

    * Booleans  — `{:bool, true}` / `{:bool, false}`. Only `{:bool, false}`
      is Scheme-falsy. Every other value is truthy, including `:null` and `0`.
    * Empty list — `:null`
    * Pair — `{:pair, car, cdr}`
    * Symbol — `{:sym, binary}` (binaries, not atoms; user-supplied
      identifiers must not exhaust the BEAM atom table)
    * String — `{:string, binary}`
    * Character — `{:char, codepoint}`
    * Exact integer — bare Elixir integer
    * Inexact real — bare Elixir float
    * Non-finite inexact — `{:float_special, :pos_inf | :neg_inf | :nan}`
      (BEAM floats cannot represent these; tagged forms carry IEEE-754
      semantics through arithmetic and comparison without smuggling
      forbidden bit patterns into Elixir floats.)
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
    * EOF — `:eof`
    * Unspecified — `:unspecified`
  """

  @type bool_v :: {:bool, boolean()}
  @type pair_v :: {:pair, t(), t()}
  @type sym_v :: {:sym, binary()}
  @type string_v :: {:string, binary()}
  @type char_v :: {:char, non_neg_integer()}
  @type vector_v :: {:vector, tuple()}
  @type bytevector_v :: {:bytevector, binary()}
  @type closure_v :: {:closure, term(), term(), term(), binary() | nil}
  @type primitive_v :: {:primitive, binary(), arity_spec(), (list() -> t())}
  @type record_v :: {:record, term(), tuple()}
  @type record_type_id_v :: {:record_type, binary(), pos_integer()}
  @type float_special_v :: {:float_special, :pos_inf | :neg_inf | :nan}
  @type arity_spec :: non_neg_integer() | {:at_least, non_neg_integer()}

  @type t ::
          bool_v()
          | :null
          | pair_v()
          | sym_v()
          | string_v()
          | char_v()
          | integer()
          | float()
          | float_special_v()
          | vector_v()
          | bytevector_v()
          | closure_v()
          | primitive_v()
          | record_v()
          | record_type_id_v()
          | :eof
          | :unspecified

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @spec bool(boolean()) :: bool_v()
  def bool(true), do: {:bool, true}
  def bool(false), do: {:bool, false}

  @spec pair(t(), t()) :: pair_v()
  def pair(car, cdr), do: {:pair, car, cdr}

  @spec symbol(binary()) :: sym_v()
  def symbol(name) when is_binary(name), do: {:sym, name}

  @spec string(binary()) :: string_v()
  def string(s) when is_binary(s), do: {:string, s}

  @spec char(non_neg_integer()) :: char_v()
  def char(cp) when is_integer(cp) and cp >= 0, do: {:char, cp}

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

  @doc "Build a Scheme list (proper, null-terminated) from an Elixir list."
  @spec list([t()]) :: t()
  def list([]), do: :null
  def list([h | t]), do: {:pair, h, list(t)}

  @doc """
  Build an improper Scheme list. The last argument becomes the cdr of the
  innermost pair.
  """
  @spec improper_list([t(), ...], t()) :: t()
  def improper_list([only], tail), do: {:pair, only, tail}
  def improper_list([h | t], tail), do: {:pair, h, improper_list(t, tail)}

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  @spec boolean?(term()) :: boolean()
  def boolean?({:bool, _}), do: true
  def boolean?(_), do: false

  @spec null?(term()) :: boolean()
  def null?(:null), do: true
  def null?(_), do: false

  @spec pair?(term()) :: boolean()
  def pair?({:pair, _, _}), do: true
  def pair?(_), do: false

  @spec symbol?(term()) :: boolean()
  def symbol?({:sym, _}), do: true
  def symbol?(_), do: false

  @spec string?(term()) :: boolean()
  def string?({:string, _}), do: true
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
  def procedure?(_), do: false

  @spec record?(term()) :: boolean()
  def record?({:record, _, _}), do: true
  def record?(_), do: false

  @spec eof?(term()) :: boolean()
  def eof?(:eof), do: true
  def eof?(_), do: false

  @doc """
  Scheme `list?` — true for `:null` and proper (null-terminated) pair chains;
  false for improper lists, atoms, and anything that ends in a non-pair non-null.
  """
  @spec list?(term()) :: boolean()
  def list?(:null), do: true
  def list?({:pair, _, cdr}), do: list?(cdr)
  def list?(_), do: false

  @spec unspecified?(term()) :: boolean()
  def unspecified?(:unspecified), do: true
  def unspecified?(_), do: false

  @spec number?(term()) :: boolean()
  def number?(n) when is_integer(n) or is_float(n), do: true
  def number?({:float_special, k}) when k in [:pos_inf, :neg_inf, :nan], do: true
  def number?(_), do: false

  @spec integer?(term()) :: boolean()
  def integer?(n) when is_integer(n), do: true
  def integer?(n) when is_float(n), do: integer_valued_float?(n)
  def integer?(_), do: false

  defp integer_valued_float?(f) do
    trunc(f) == f
  rescue
    ArgumentError -> false
  end

  @spec exact?(term()) :: boolean()
  def exact?(n) when is_integer(n), do: true
  def exact?(_), do: false

  @spec inexact?(term()) :: boolean()
  def inexact?(n) when is_float(n), do: true
  def inexact?({:float_special, k}) when k in [:pos_inf, :neg_inf, :nan], do: true
  def inexact?(_), do: false

  @spec float_special?(term()) :: boolean()
  def float_special?({:float_special, k}) when k in [:pos_inf, :neg_inf, :nan], do: true
  def float_special?(_), do: false

  @doc """
  Scheme truthiness: only `{:bool, false}` is false; every other value is
  truthy, including `:null`, `0`, and the empty string.
  """
  @spec truthy?(t()) :: boolean()
  def truthy?({:bool, false}), do: false
  def truthy?(_), do: true

  # ---------------------------------------------------------------------------
  # Equality
  # ---------------------------------------------------------------------------

  @doc """
  Scheme `eq?`. In a fully immutable value model `eq?` is indistinguishable
  from `eqv?` — there is no observable identity beyond structural value, so
  the two collapse together. r7rs explicitly permits this.
  """
  @spec eq?(t(), t()) :: boolean()
  def eq?(a, b), do: eqv?(a, b)

  @doc """
  Scheme `eqv?`. Numerically equal numbers compare equal only if they share
  exactness — `(eqv? 1 1.0)` is `#f`. Erlang's `===` already enforces this
  because integers and floats are distinct terms.
  """
  @spec eqv?(t(), t()) :: boolean()
  # IEEE-754: NaN is never equal to anything, including another NaN.
  def eqv?({:float_special, :nan}, _), do: false
  def eqv?(_, {:float_special, :nan}), do: false
  def eqv?(a, b), do: a === b

  @doc """
  Scheme `equal?`. Recurses structurally into pairs, vectors, bytevectors,
  strings, and records. For everything else it falls through to `eqv?`.
  """
  @spec equal?(t(), t()) :: boolean()
  # IEEE-754: NaN is never equal to anything, including another NaN.
  def equal?({:float_special, :nan}, _), do: false
  def equal?(_, {:float_special, :nan}), do: false
  def equal?(a, a), do: true
  def equal?({:pair, a1, b1}, {:pair, a2, b2}), do: equal?(a1, a2) and equal?(b1, b2)
  def equal?({:vector, t1}, {:vector, t2}), do: equal_tuples?(t1, t2)
  def equal?({:string, s1}, {:string, s2}), do: s1 == s2
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

  defp render({:bool, true}, _), do: "#t"
  defp render({:bool, false}, _), do: "#f"
  defp render(:null, _), do: "()"
  defp render(:eof, _), do: "#<eof>"
  defp render(:unspecified, _), do: "#<unspecified>"
  defp render({:sym, name}, _), do: render_symbol(name)
  defp render({:string, s}, :write), do: [?", escape_string(s), ?"]
  defp render({:string, s}, :display), do: s
  defp render({:char, cp}, :write), do: render_char_write(cp)
  defp render({:char, cp}, :display), do: <<cp::utf8>>
  defp render({:bytevector, b}, _), do: render_bytevector(b)
  defp render({:vector, t}, mode), do: render_vector(t, mode)
  defp render({:pair, _, _} = p, mode), do: render_pair(p, mode)
  defp render({:closure, _, _, _, name}, _), do: render_closure(name)
  defp render({:primitive, name, _, _}, _), do: ["#<primitive ", name, ">"]
  defp render({:record, {:record_type, name, _}, _}, _), do: ["#<record ", name, ">"]
  defp render({:record, type_id, _}, _), do: ["#<record ", inspect(type_id), ">"]
  defp render({:float_special, :pos_inf}, _), do: "+inf.0"
  defp render({:float_special, :neg_inf}, _), do: "-inf.0"
  defp render({:float_special, :nan}, _), do: "+nan.0"
  defp render(n, _) when is_integer(n), do: Integer.to_string(n)
  defp render(n, _) when is_float(n), do: render_float(n)

  defp render_pair(pair, mode) do
    {items, tail} = collect_pair(pair, [])

    head = items |> Enum.reverse() |> Enum.map(&render(&1, mode)) |> Enum.intersperse(?\s)

    case tail do
      :null -> [?(, head, ?)]
      _ -> [?(, head, " . ", render(tail, mode), ?)]
    end
  end

  defp collect_pair({:pair, car, cdr}, acc), do: collect_pair(cdr, [car | acc])
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

  defp render_float(f) do
    s = :erlang.float_to_binary(f, [:short])
    if String.contains?(s, ".") or String.contains?(s, "e"), do: s, else: s <> ".0"
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

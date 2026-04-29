defmodule Schooner.Primitives.Char do
  @moduledoc """
  The `(scheme char)` library: codepoint conversion, comparators (case
  sensitive and case-insensitive), case mappings, and category
  predicates.

  Schooner characters are single Unicode scalar values stored as
  `{:char, codepoint}`. Case mappings that would expand to multiple
  codepoints (e.g. `ß` → `SS`) leave the original character unchanged
  — char-level mappings preserve the one-codepoint shape, and the
  longer mapping is reachable through the string ops.
  """

  alias Schooner.Primitive.Error
  alias Schooner.Value

  @alpha_re ~r/^\p{L}$/u
  @numeric_re ~r/^\p{Nd}$/u
  @upper_re ~r/^\p{Lu}$/u
  @lower_re ~r/^\p{Ll}$/u
  # r7rs whitespace = Unicode Z* + the ASCII control whitespace (HT, LF, VT, FF, CR).
  @whitespace_re ~r/^[\p{Z}\t\n\v\f\r]$/u

  @doc """
  Return every `(scheme char)` primitive as a `{name, arity, fun}`
  tuple. Used by `Schooner.Library.Standard` to assemble
  `(scheme char)`.
  """
  @spec specs() :: [{binary(), non_neg_integer() | {:at_least, non_neg_integer()}, fun()}]
  def specs do
    [
      {"char->integer", 1, &char_to_integer/1},
      {"integer->char", 1, &integer_to_char/1},
      {"char=?", {:at_least, 2}, &char_eq/1},
      {"char<?", {:at_least, 2}, &char_lt/1},
      {"char<=?", {:at_least, 2}, &char_le/1},
      {"char>?", {:at_least, 2}, &char_gt/1},
      {"char>=?", {:at_least, 2}, &char_ge/1},
      {"char-ci=?", {:at_least, 2}, &char_ci_eq/1},
      {"char-ci<?", {:at_least, 2}, &char_ci_lt/1},
      {"char-ci<=?", {:at_least, 2}, &char_ci_le/1},
      {"char-ci>?", {:at_least, 2}, &char_ci_gt/1},
      {"char-ci>=?", {:at_least, 2}, &char_ci_ge/1},
      {"char-upcase", 1, &char_upcase/1},
      {"char-downcase", 1, &char_downcase/1},
      {"char-foldcase", 1, &char_foldcase/1},
      {"char-alphabetic?", 1, &char_alphabetic_p/1},
      {"char-numeric?", 1, &char_numeric_p/1},
      {"char-whitespace?", 1, &char_whitespace_p/1},
      {"char-upper-case?", 1, &char_upper_case_p/1},
      {"char-lower-case?", 1, &char_lower_case_p/1},
      {"digit-value", 1, &digit_value/1}
    ]
  end

  # ---------------------------------------------------------------------------
  # Conversion
  # ---------------------------------------------------------------------------

  defp char_to_integer([{:char, cp}]), do: cp

  defp char_to_integer([other]),
    do: raise(Error, reason: {:type_error, "char->integer", "char", other})

  defp integer_to_char([n]) when is_integer(n) and n >= 0 and n <= 0x10FFFF do
    if surrogate?(n) do
      raise(Error, reason: {:codepoint_out_of_range, "integer->char", n})
    else
      Value.char(n)
    end
  end

  defp integer_to_char([n]) when is_integer(n),
    do: raise(Error, reason: {:codepoint_out_of_range, "integer->char", n})

  defp integer_to_char([other]),
    do: raise(Error, reason: {:type_error, "integer->char", "integer", other})

  defp surrogate?(cp), do: cp >= 0xD800 and cp <= 0xDFFF

  # ---------------------------------------------------------------------------
  # Comparators (case-sensitive and case-insensitive)
  # ---------------------------------------------------------------------------

  defp char_eq(args), do: variadic_char_cmp("char=?", args, & &1, &(&1 == &2))
  defp char_lt(args), do: variadic_char_cmp("char<?", args, & &1, &(&1 < &2))
  defp char_le(args), do: variadic_char_cmp("char<=?", args, & &1, &(&1 <= &2))
  defp char_gt(args), do: variadic_char_cmp("char>?", args, & &1, &(&1 > &2))
  defp char_ge(args), do: variadic_char_cmp("char>=?", args, & &1, &(&1 >= &2))

  defp char_ci_eq(args), do: variadic_char_cmp("char-ci=?", args, &fold/1, &(&1 == &2))
  defp char_ci_lt(args), do: variadic_char_cmp("char-ci<?", args, &fold/1, &(&1 < &2))
  defp char_ci_le(args), do: variadic_char_cmp("char-ci<=?", args, &fold/1, &(&1 <= &2))
  defp char_ci_gt(args), do: variadic_char_cmp("char-ci>?", args, &fold/1, &(&1 > &2))
  defp char_ci_ge(args), do: variadic_char_cmp("char-ci>=?", args, &fold/1, &(&1 >= &2))

  defp variadic_char_cmp(op, [first | rest] = args, key_fn, pair) do
    Enum.each(args, &require_char!(op, &1))
    {:char, h} = first
    Value.bool(walk_chars(rest, key_fn.(h), key_fn, pair))
  end

  defp walk_chars([], _prev, _key_fn, _pair), do: true

  defp walk_chars([{:char, cp} | rest], prev, key_fn, pair) do
    k = key_fn.(cp)
    if pair.(prev, k), do: walk_chars(rest, k, key_fn, pair), else: false
  end

  defp fold(cp) do
    case String.to_charlist(String.downcase(<<cp::utf8>>, :default)) do
      [single] -> single
      _ -> cp
    end
  end

  # ---------------------------------------------------------------------------
  # Case mappings
  # ---------------------------------------------------------------------------

  defp char_upcase([{:char, cp}]), do: Value.char(map_case(cp, &String.upcase/2))

  defp char_upcase([other]),
    do: raise(Error, reason: {:type_error, "char-upcase", "char", other})

  defp char_downcase([{:char, cp}]), do: Value.char(map_case(cp, &String.downcase/2))

  defp char_downcase([other]),
    do: raise(Error, reason: {:type_error, "char-downcase", "char", other})

  defp char_foldcase([{:char, cp}]), do: Value.char(fold(cp))

  defp char_foldcase([other]),
    do: raise(Error, reason: {:type_error, "char-foldcase", "char", other})

  # If the case mapping yields more than one codepoint, fall back to the
  # original — char ops must preserve single-codepoint identity.
  defp map_case(cp, mapper) do
    case String.to_charlist(mapper.(<<cp::utf8>>, :default)) do
      [single] -> single
      _ -> cp
    end
  end

  # ---------------------------------------------------------------------------
  # Category predicates
  # ---------------------------------------------------------------------------

  defp char_alphabetic_p([{:char, cp}]) when cp in ?A..?Z or cp in ?a..?z, do: Value.bool(true)
  defp char_alphabetic_p([{:char, cp}]) when cp < 128, do: Value.bool(false)
  defp char_alphabetic_p([{:char, cp}]), do: Value.bool(Regex.match?(@alpha_re, <<cp::utf8>>))
  defp char_alphabetic_p([other]), do: raise_char("char-alphabetic?", other)

  defp char_numeric_p([{:char, cp}]) when cp in ?0..?9, do: Value.bool(true)
  defp char_numeric_p([{:char, cp}]) when cp < 128, do: Value.bool(false)
  defp char_numeric_p([{:char, cp}]), do: Value.bool(Regex.match?(@numeric_re, <<cp::utf8>>))
  defp char_numeric_p([other]), do: raise_char("char-numeric?", other)

  defp char_whitespace_p([{:char, cp}]) when cp in [?\s, ?\t, ?\n, ?\r, ?\v, ?\f],
    do: Value.bool(true)

  defp char_whitespace_p([{:char, cp}]) when cp < 128, do: Value.bool(false)

  defp char_whitespace_p([{:char, cp}]),
    do: Value.bool(Regex.match?(@whitespace_re, <<cp::utf8>>))

  defp char_whitespace_p([other]), do: raise_char("char-whitespace?", other)

  defp char_upper_case_p([{:char, cp}]) when cp in ?A..?Z, do: Value.bool(true)
  defp char_upper_case_p([{:char, cp}]) when cp < 128, do: Value.bool(false)
  defp char_upper_case_p([{:char, cp}]), do: Value.bool(Regex.match?(@upper_re, <<cp::utf8>>))
  defp char_upper_case_p([other]), do: raise_char("char-upper-case?", other)

  defp char_lower_case_p([{:char, cp}]) when cp in ?a..?z, do: Value.bool(true)
  defp char_lower_case_p([{:char, cp}]) when cp < 128, do: Value.bool(false)
  defp char_lower_case_p([{:char, cp}]), do: Value.bool(Regex.match?(@lower_re, <<cp::utf8>>))
  defp char_lower_case_p([other]), do: raise_char("char-lower-case?", other)

  defp raise_char(op, other),
    do: raise(Error, reason: {:type_error, op, "char", other})

  # ---------------------------------------------------------------------------
  # Digit value
  # ---------------------------------------------------------------------------

  # Per r7rs §6.6: returns the numeric value (0..9) of a Unicode Nd
  # character, or #f for any other character. Each Nd block spans exactly
  # ten consecutive codepoints starting at a "digit zero", so the digit
  # value of `cp` equals its offset from the start of its block — found
  # by walking down until the codepoint stops being Nd.
  defp digit_value([{:char, cp}]) when cp in ?0..?9, do: cp - ?0
  defp digit_value([{:char, cp}]) when cp < 128, do: Value.bool(false)

  defp digit_value([{:char, cp}]) do
    if Regex.match?(@numeric_re, <<cp::utf8>>) do
      nd_block_offset(cp, 0)
    else
      Value.bool(false)
    end
  end

  defp digit_value([other]),
    do: raise(Error, reason: {:type_error, "digit-value", "char", other})

  defp nd_block_offset(_cp, 9), do: 9

  defp nd_block_offset(cp, n) do
    prev = cp - 1

    if prev >= 0 and Regex.match?(@numeric_re, <<prev::utf8>>) do
      nd_block_offset(prev, n + 1)
    else
      n
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp require_char!(_op, {:char, _}), do: :ok

  defp require_char!(op, other),
    do: raise(Error, reason: {:type_error, op, "char", other})
end

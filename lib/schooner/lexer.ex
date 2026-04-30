defmodule Schooner.Lexer do
  @moduledoc """
  Hand-rolled lexer turning Scheme source text into a flat token stream.

  Every token carries the `{line, column}` of its first character so the
  reader, expander, and error reporters downstream can quote source
  locations back to the user without keeping the original string around.

  ## Token shape

  Tokens are 3-tuples `{tag, value, position}` where:

    * `tag` is one of the atoms enumerated in `t:tag/0`
    * `value` is `nil` for tokens whose tag is self-describing (parens,
      quote markers, dot, vector opens) and the parsed payload for the rest
    * `position` is `{line, column}`, both 1-based

  ## Errors

  Lexer errors are raised as `Schooner.Lexer.Error` with a structured
  reason and the source position at which the offending input begins.
  Errors are exceptions rather than tagged tuples because every caller
  in the pipeline (reader, embedding API) treats a lex failure as fatal
  for the current source unit.
  """

  alias Schooner.Lexer.Error
  alias Schooner.Value

  @type position :: {pos_integer(), pos_integer()}

  @type tag ::
          :lparen
          | :rparen
          | :vector_open
          | :bytevector_open
          | :quote
          | :quasiquote
          | :unquote
          | :unquote_splicing
          | :dot
          | :ident
          | :integer
          | :rational
          | :float
          | :complex
          | :string
          | :char
          | :bool
          | :datum_comment

  @type token :: {tag(), term(), position()}

  # Characters that terminate an "atom" (an identifier or numeric literal).
  @terminators [?\s, ?\t, ?\r, ?\n, ?(, ?), ?[, ?], ?{, ?}, ?", ?;, ?|, ?', ?`, ?,]

  @doc """
  Tokenise a Scheme source binary into a list of tokens.

  Whitespace, line comments (`;`), nested block comments (`#| ... |#`)
  and datum comments (`#;`) are recognised. Whitespace and the comment
  bodies are dropped; `#;` is preserved as a sentinel `:datum_comment`
  token because the lexer cannot know how much of the following stream
  forms the next datum — that is the reader's job.

  Raises `Schooner.Lexer.Error` on malformed input.
  """
  @spec tokenise(binary()) :: [token()]
  def tokenise(source) when is_binary(source) do
    scan(source, 1, 1, [])
  end

  # ---------------------------------------------------------------------------
  # Top-level scanner
  # ---------------------------------------------------------------------------

  defp scan(<<>>, _line, _col, acc), do: Enum.reverse(acc)

  # newlines
  defp scan(<<?\r, ?\n, rest::binary>>, line, _col, acc), do: scan(rest, line + 1, 1, acc)
  defp scan(<<?\n, rest::binary>>, line, _col, acc), do: scan(rest, line + 1, 1, acc)
  defp scan(<<?\r, rest::binary>>, line, _col, acc), do: scan(rest, line + 1, 1, acc)

  # spaces / tabs
  defp scan(<<c, rest::binary>>, line, col, acc) when c in [?\s, ?\t] do
    scan(rest, line, col + 1, acc)
  end

  # line comment
  defp scan(<<?;, rest::binary>>, line, col, acc) do
    {rest, line, col} = skip_line(rest, line, col + 1)
    scan(rest, line, col, acc)
  end

  # block comment / datum comment / hash forms
  defp scan(<<?#, ?|, rest::binary>>, line, col, acc) do
    {rest, line, col} = skip_block(rest, line, col + 2, 1, {line, col})
    scan(rest, line, col, acc)
  end

  defp scan(<<?#, ?;, rest::binary>>, line, col, acc) do
    scan(rest, line, col + 2, [{:datum_comment, nil, {line, col}} | acc])
  end

  defp scan(<<?#, ?u, ?8, ?(, rest::binary>>, line, col, acc) do
    scan(rest, line, col + 4, [{:bytevector_open, nil, {line, col}} | acc])
  end

  defp scan(<<?#, ?(, rest::binary>>, line, col, acc) do
    scan(rest, line, col + 2, [{:vector_open, nil, {line, col}} | acc])
  end

  defp scan(<<?#, ?\\, rest::binary>>, line, col, acc) do
    {token, rest, col2} = read_char(rest, line, col + 2, {line, col})
    scan(rest, line, col2, [token | acc])
  end

  defp scan(<<?#, c, _::binary>> = src, line, col, acc)
       when c in [?e, ?i, ?b, ?o, ?d, ?x, ?E, ?I, ?B, ?D, ?O, ?X] do
    {token, rest, col2} = read_prefixed_number(src, line, col)
    scan(rest, line, col2, [token | acc])
  end

  defp scan(<<?#, ?t, ?r, ?u, ?e, rest::binary>>, line, col, acc) do
    finish_bool(rest, line, col, 5, true, acc)
  end

  defp scan(<<?#, ?f, ?a, ?l, ?s, ?e, rest::binary>>, line, col, acc) do
    finish_bool(rest, line, col, 6, false, acc)
  end

  defp scan(<<?#, ?t, rest::binary>>, line, col, acc) do
    finish_bool(rest, line, col, 2, true, acc)
  end

  defp scan(<<?#, ?f, rest::binary>>, line, col, acc) do
    finish_bool(rest, line, col, 2, false, acc)
  end

  defp scan(<<?#, c, _::binary>>, line, col, _acc) do
    raise Error, reason: {:invalid_hash_form, c}, position: {line, col}
  end

  # punctuation
  defp scan(<<?(, rest::binary>>, line, col, acc) do
    scan(rest, line, col + 1, [{:lparen, nil, {line, col}} | acc])
  end

  defp scan(<<?), rest::binary>>, line, col, acc) do
    scan(rest, line, col + 1, [{:rparen, nil, {line, col}} | acc])
  end

  defp scan(<<?', rest::binary>>, line, col, acc) do
    scan(rest, line, col + 1, [{:quote, nil, {line, col}} | acc])
  end

  defp scan(<<?`, rest::binary>>, line, col, acc) do
    scan(rest, line, col + 1, [{:quasiquote, nil, {line, col}} | acc])
  end

  defp scan(<<?,, ?@, rest::binary>>, line, col, acc) do
    scan(rest, line, col + 2, [{:unquote_splicing, nil, {line, col}} | acc])
  end

  defp scan(<<?,, rest::binary>>, line, col, acc) do
    scan(rest, line, col + 1, [{:unquote, nil, {line, col}} | acc])
  end

  # vertical-bar identifier
  defp scan(<<?|, rest::binary>>, line, col, acc) do
    {name, rest, line2, col2} = read_bar_ident(rest, line, col + 1, {line, col}, [])
    scan(rest, line2, col2, [{:ident, name, {line, col}} | acc])
  end

  # string literal
  defp scan(<<?", rest::binary>>, line, col, acc) do
    {str, rest, line2, col2} = read_string(rest, line, col + 1, {line, col}, [])
    scan(rest, line2, col2, [{:string, str, {line, col}} | acc])
  end

  # numbers, peculiar identifiers, dots, identifiers
  defp scan(<<c, _::binary>> = src, line, col, acc) do
    cond do
      c in ?0..?9 ->
        {token, rest, col2} = read_atom_token(src, line, col, :auto, false)
        scan(rest, line, col2, [token | acc])

      c in [?+, ?-] ->
        {token, rest, col2} = read_atom_token(src, line, col, :auto, true)
        scan(rest, line, col2, [token | acc])

      c == ?. ->
        {token, rest, col2} = read_dot_token(src, line, col)
        scan(rest, line, col2, [token | acc])

      identifier_start?(c) ->
        {token, rest, col2} = read_atom_token(src, line, col, :auto, false)
        scan(rest, line, col2, [token | acc])

      true ->
        raise Error, reason: {:unexpected_char, c}, position: {line, col}
    end
  end

  # ---------------------------------------------------------------------------
  # Comments
  # ---------------------------------------------------------------------------

  defp skip_line(<<>>, line, col), do: {<<>>, line, col}
  defp skip_line(<<?\r, ?\n, rest::binary>>, line, _col), do: {rest, line + 1, 1}
  defp skip_line(<<?\n, rest::binary>>, line, _col), do: {rest, line + 1, 1}
  defp skip_line(<<?\r, rest::binary>>, line, _col), do: {rest, line + 1, 1}

  defp skip_line(<<_c::utf8, rest::binary>>, line, col) do
    skip_line(rest, line, col + 1)
  end

  defp skip_block(<<>>, _line, _col, _depth, start) do
    raise Error, reason: :unterminated_block_comment, position: start
  end

  defp skip_block(<<?|, ?#, rest::binary>>, line, col, 1, _start) do
    {rest, line, col + 2}
  end

  defp skip_block(<<?|, ?#, rest::binary>>, line, col, depth, start) do
    skip_block(rest, line, col + 2, depth - 1, start)
  end

  defp skip_block(<<?#, ?|, rest::binary>>, line, col, depth, start) do
    skip_block(rest, line, col + 2, depth + 1, start)
  end

  defp skip_block(<<?\r, ?\n, rest::binary>>, line, _col, depth, start) do
    skip_block(rest, line + 1, 1, depth, start)
  end

  defp skip_block(<<?\n, rest::binary>>, line, _col, depth, start) do
    skip_block(rest, line + 1, 1, depth, start)
  end

  defp skip_block(<<?\r, rest::binary>>, line, _col, depth, start) do
    skip_block(rest, line + 1, 1, depth, start)
  end

  defp skip_block(<<_c::utf8, rest::binary>>, line, col, depth, start) do
    skip_block(rest, line, col + 1, depth, start)
  end

  # ---------------------------------------------------------------------------
  # Booleans
  # ---------------------------------------------------------------------------

  defp finish_bool(rest, line, col, consumed, value, acc) do
    case rest do
      <<c, _::binary>> when c not in @terminators ->
        raise Error, reason: {:invalid_boolean, c}, position: {line, col}

      _ ->
        scan(rest, line, col + consumed, [{:bool, value, {line, col}} | acc])
    end
  end

  # ---------------------------------------------------------------------------
  # Characters
  # ---------------------------------------------------------------------------

  @char_names %{
    "alarm" => 7,
    "backspace" => 8,
    "delete" => 127,
    "escape" => 27,
    "newline" => 10,
    "null" => 0,
    "return" => 13,
    "space" => 32,
    "tab" => 9
  }

  # `#\` already consumed.
  defp read_char(src, _line, col, start) do
    case scan_char_run(src, []) do
      {[], <<cp::utf8, rest::binary>>} -> {{:char, cp, start}, rest, col + 1}
      {[], <<>>} -> raise Error, reason: :unterminated_char_literal, position: start
      {[only], rest} -> {{:char, only, start}, rest, col + 1}
      {chars, rest} -> read_named_or_hex_char(chars, rest, col, start)
    end
  end

  defp read_named_or_hex_char(chars, rest, col, start) do
    body = chars |> Enum.reverse() |> List.to_string()
    cp = decode_named_or_hex_char(body, start)
    {{:char, cp, start}, rest, col + String.length(body)}
  end

  defp scan_char_run(<<c::utf8, rest::binary>>, acc) do
    if char_run?(c) do
      scan_char_run(rest, [c | acc])
    else
      {acc, <<c::utf8, rest::binary>>}
    end
  end

  defp scan_char_run(<<>>, acc), do: {acc, <<>>}

  defp char_run?(c), do: c not in @terminators

  defp decode_named_or_hex_char(<<?x, rest::binary>>, start) when byte_size(rest) > 0 do
    if all_hex_digits?(rest) do
      String.to_integer(rest, 16)
    else
      named_char(<<?x, rest::binary>>, start)
    end
  end

  defp decode_named_or_hex_char(name, start), do: named_char(name, start)

  defp named_char(name, start) do
    case Map.fetch(@char_names, name) do
      {:ok, cp} -> cp
      :error -> raise Error, reason: {:unknown_char_name, name}, position: start
    end
  end

  # ---------------------------------------------------------------------------
  # Strings
  # ---------------------------------------------------------------------------

  defp read_string(<<>>, _line, _col, start, _acc) do
    raise Error, reason: :unterminated_string, position: start
  end

  defp read_string(<<?", rest::binary>>, line, col, _start, acc) do
    body = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {body, rest, line, col + 1}
  end

  defp read_string(<<?\\, rest::binary>>, line, col, start, acc) do
    {chunk, rest, line, col} = string_escape(rest, line, col + 1, start)
    read_string(rest, line, col, start, [chunk | acc])
  end

  defp read_string(<<?\r, ?\n, rest::binary>>, line, _col, start, acc) do
    read_string(rest, line + 1, 1, start, [?\n | acc])
  end

  defp read_string(<<?\n, rest::binary>>, line, _col, start, acc) do
    read_string(rest, line + 1, 1, start, [?\n | acc])
  end

  defp read_string(<<?\r, rest::binary>>, line, _col, start, acc) do
    read_string(rest, line + 1, 1, start, [?\n | acc])
  end

  defp read_string(<<c::utf8, rest::binary>>, line, col, start, acc) do
    read_string(rest, line, col + 1, start, [<<c::utf8>> | acc])
  end

  defp string_escape(<<>>, _line, _col, start) do
    raise Error, reason: :unterminated_string, position: start
  end

  defp string_escape(<<?n, rest::binary>>, line, col, _s), do: {?\n, rest, line, col + 1}
  defp string_escape(<<?t, rest::binary>>, line, col, _s), do: {?\t, rest, line, col + 1}
  defp string_escape(<<?r, rest::binary>>, line, col, _s), do: {?\r, rest, line, col + 1}
  defp string_escape(<<?b, rest::binary>>, line, col, _s), do: {?\b, rest, line, col + 1}
  defp string_escape(<<?a, rest::binary>>, line, col, _s), do: {7, rest, line, col + 1}
  defp string_escape(<<?", rest::binary>>, line, col, _s), do: {?", rest, line, col + 1}
  defp string_escape(<<?\\, rest::binary>>, line, col, _s), do: {?\\, rest, line, col + 1}
  defp string_escape(<<?|, rest::binary>>, line, col, _s), do: {?|, rest, line, col + 1}

  defp string_escape(<<?x, rest::binary>>, line, col, _start) do
    {cp, rest, taken} = read_hex_escape(rest, {line, col - 1})
    {<<cp::utf8>>, rest, line, col + 1 + taken}
  end

  defp string_escape(<<c, _::binary>>, line, col, _start) do
    raise Error, reason: {:invalid_escape, c}, position: {line, col - 1}
  end

  defp read_hex_escape(rest, start), do: read_hex_escape(rest, start, [])

  defp read_hex_escape(<<?;, _rest::binary>>, start, []) do
    raise Error, reason: :empty_hex_escape, position: start
  end

  defp read_hex_escape(<<?;, rest::binary>>, _start, acc) do
    digits = acc |> Enum.reverse() |> List.to_string()
    {String.to_integer(digits, 16), rest, byte_size(digits) + 1}
  end

  defp read_hex_escape(<<c, rest::binary>>, start, acc)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    read_hex_escape(rest, start, [c | acc])
  end

  defp read_hex_escape(_rest, start, _acc) do
    raise Error, reason: :unterminated_hex_escape, position: start
  end

  # ---------------------------------------------------------------------------
  # Bar-quoted identifiers
  # ---------------------------------------------------------------------------

  defp read_bar_ident(<<>>, _line, _col, start, _acc) do
    raise Error, reason: :unterminated_bar_identifier, position: start
  end

  defp read_bar_ident(<<?|, rest::binary>>, line, col, _start, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, line, col + 1}
  end

  defp read_bar_ident(<<?\\, ?|, rest::binary>>, line, col, start, acc) do
    read_bar_ident(rest, line, col + 2, start, [?| | acc])
  end

  defp read_bar_ident(<<?\\, ?\\, rest::binary>>, line, col, start, acc) do
    read_bar_ident(rest, line, col + 2, start, [?\\ | acc])
  end

  defp read_bar_ident(<<?\\, ?n, rest::binary>>, line, col, start, acc) do
    read_bar_ident(rest, line, col + 2, start, [?\n | acc])
  end

  defp read_bar_ident(<<?\\, ?t, rest::binary>>, line, col, start, acc) do
    read_bar_ident(rest, line, col + 2, start, [?\t | acc])
  end

  defp read_bar_ident(<<?\\, ?x, rest::binary>>, line, col, start, acc) do
    {cp, rest, taken} = read_hex_escape(rest, start)
    read_bar_ident(rest, line, col + 2 + taken, start, [<<cp::utf8>> | acc])
  end

  defp read_bar_ident(<<?\r, ?\n, rest::binary>>, line, _col, start, acc) do
    read_bar_ident(rest, line + 1, 1, start, [?\n | acc])
  end

  defp read_bar_ident(<<?\n, rest::binary>>, line, _col, start, acc) do
    read_bar_ident(rest, line + 1, 1, start, [?\n | acc])
  end

  defp read_bar_ident(<<c::utf8, rest::binary>>, line, col, start, acc) do
    read_bar_ident(rest, line, col + 1, start, [<<c::utf8>> | acc])
  end

  # ---------------------------------------------------------------------------
  # Numbers (with `#`-prefixes)
  # ---------------------------------------------------------------------------

  defp read_prefixed_number(src, line, col) do
    {flags, rest, taken} = consume_prefixes(src, [], 0)
    {radix, exactness} = resolve_prefix_flags(flags, line, col)
    {raw, rest, atom_len} = scan_atom(rest, [])

    if raw == "" do
      raise Error, reason: :invalid_numeric_literal, position: {line, col}
    end

    case parse_number(raw, radix, exactness) do
      {:ok, n} when is_integer(n) ->
        {{:integer, n, {line, col}}, rest, col + taken + atom_len}

      {:ok, f} when is_float(f) ->
        {{:float, f, {line, col}}, rest, col + taken + atom_len}

      {:ok, {:rational, _, _} = r} ->
        {{:rational, r, {line, col}}, rest, col + taken + atom_len}

      :error ->
        raise Error, reason: {:invalid_numeric_literal, raw}, position: {line, col}
    end
  end

  @radix_flags %{?b => 2, ?B => 2, ?o => 8, ?O => 8, ?d => 10, ?D => 10, ?x => 16, ?X => 16}
  @exactness_flags %{?e => :exact, ?E => :exact, ?i => :inexact, ?I => :inexact}

  defp consume_prefixes(<<?#, c, rest::binary>>, acc, taken)
       when is_map_key(@radix_flags, c) or is_map_key(@exactness_flags, c) do
    consume_prefixes(rest, [c | acc], taken + 2)
  end

  defp consume_prefixes(rest, acc, taken), do: {Enum.reverse(acc), rest, taken}

  defp resolve_prefix_flags(flags, line, col) do
    Enum.reduce(flags, {nil, nil}, fn flag, {r, e} ->
      case {Map.get(@radix_flags, flag), Map.get(@exactness_flags, flag)} do
        {nil, exact} -> {r, set_once(e, exact, :exactness, line, col)}
        {radix, nil} -> {set_once(r, radix, :radix, line, col), e}
      end
    end)
    |> then(fn {r, e} -> {r || 10, e || :auto} end)
  end

  defp set_once(nil, value, _which, _line, _col), do: value

  defp set_once(_existing, _value, which, line, col) do
    raise Error, reason: {:duplicate_number_prefix, which}, position: {line, col}
  end

  # ---------------------------------------------------------------------------
  # Atom scanning (numbers, peculiar identifiers, plain identifiers)
  # ---------------------------------------------------------------------------

  defp read_atom_token(src, line, col, exactness, allow_sign?) do
    {raw, rest, taken} = scan_atom(src, [])
    token = classify_atom(raw, line, col, exactness, allow_sign?)
    {token, rest, col + taken}
  end

  defp scan_atom(<<>>, acc), do: build_atom(acc, <<>>)

  defp scan_atom(<<c, rest::binary>>, acc) when c in @terminators do
    build_atom(acc, <<c, rest::binary>>)
  end

  defp scan_atom(<<c::utf8, rest::binary>>, acc) do
    scan_atom(rest, [<<c::utf8>> | acc])
  end

  defp build_atom(acc, rest) do
    body = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {body, rest, String.length(body)}
  end

  defp classify_atom(raw, line, col, exactness, allow_sign?) do
    case atom_kind(raw, allow_sign?) do
      :empty -> raise Error, reason: :empty_atom, position: {line, col}
      :ident -> {:ident, raw, {line, col}}
      {:float_special, value} -> {:float, value, {line, col}}
      {:complex_literal, parts} -> complex_token(raw, parts, line, col, exactness)
      :numeric -> numeric_token(raw, line, col, exactness)
      :invalid -> raise Error, reason: {:invalid_token, raw}, position: {line, col}
    end
  end

  # Build a `:complex` token from a `complex_atom_parts/1` match. The
  # raw string parts are re-parsed as full Scheme numerics so each
  # half tracks the prevailing exactness flags consistently with the
  # standalone-number path.
  defp complex_token(raw, {real_raw, imag_raw}, line, col, exactness)
       when is_binary(real_raw) and is_binary(imag_raw) do
    real = parse_complex_part(real_raw, exactness, raw, line, col)
    imag = parse_complex_part(imag_raw, exactness, raw, line, col)
    {:complex, {:complex, real, imag}, {line, col}}
  end

  defp complex_token(raw, {real_part, imag_int}, line, col, exactness)
       when is_integer(imag_int) do
    real =
      cond do
        is_integer(real_part) -> lift_int(real_part, exactness)
        is_binary(real_part) -> parse_complex_part(real_part, exactness, raw, line, col)
      end

    imag = lift_int(imag_int, exactness)
    {:complex, {:complex, real, imag}, {line, col}}
  end

  # Polar literal `mag@ang` → rectangular floats. The trig step
  # forces inexact components, mirroring `(make-polar mag ang)`.
  defp complex_token(raw, {:polar, mag_raw, ang_raw}, line, col, _exactness) do
    mag = parse_polar_part(mag_raw, raw, line, col)
    ang = parse_polar_part(ang_raw, raw, line, col)
    {:complex, {:complex, mag * :math.cos(ang), mag * :math.sin(ang)}, {line, col}}
  end

  defp parse_polar_part(raw, whole, line, col) do
    case parse_number(raw, 10, :auto) do
      {:ok, n} when is_integer(n) -> n * 1.0
      {:ok, f} when is_float(f) -> f
      {:ok, {:rational, n, d}} -> n / d
      :error -> raise Error, reason: {:invalid_numeric_literal, whole}, position: {line, col}
    end
  end

  defp lift_int(n, :inexact), do: n / 1
  defp lift_int(n, _), do: n

  defp parse_complex_part(raw, exactness, _whole, _line, _col) when is_integer(raw),
    do: lift_int(raw, exactness)

  defp parse_complex_part("+inf.0", _exactness, _whole, _line, _col),
    do: {:float_special, :pos_inf}

  defp parse_complex_part("-inf.0", _exactness, _whole, _line, _col),
    do: {:float_special, :neg_inf}

  defp parse_complex_part("+nan.0", _exactness, _whole, _line, _col),
    do: {:float_special, :nan}

  defp parse_complex_part("-nan.0", _exactness, _whole, _line, _col),
    do: {:float_special, :nan}

  defp parse_complex_part(raw, exactness, whole, line, col) do
    case parse_number(raw, 10, exactness) do
      {:ok, n} -> n
      :error -> raise Error, reason: {:invalid_numeric_literal, whole}, position: {line, col}
    end
  end

  defp atom_kind("", _allow_sign?), do: :empty
  defp atom_kind(raw, _allow_sign?) when raw in ["...", "->"], do: :ident
  defp atom_kind(raw, true) when raw in ["+", "-"], do: :ident
  defp atom_kind("+inf.0", _), do: {:float_special, special_float("+inf.0")}
  defp atom_kind("-inf.0", _), do: {:float_special, special_float("-inf.0")}
  defp atom_kind("+nan.0", _), do: {:float_special, special_float("+nan.0")}
  defp atom_kind("-nan.0", _), do: {:float_special, special_float("-nan.0")}
  defp atom_kind("+i", _), do: {:complex_literal, {0, 1}}
  defp atom_kind("-i", _), do: {:complex_literal, {0, -1}}

  defp atom_kind(raw, _allow_sign?) do
    if starts_with_arrow?(raw) do
      :ident
    else
      classify_non_arrow_atom(raw)
    end
  end

  defp classify_non_arrow_atom(raw) do
    case complex_atom_parts(raw) do
      :no_match -> classify_plain_atom(raw)
      parts -> {:complex_literal, parts}
    end
  end

  defp classify_plain_atom(raw) do
    cond do
      numeric_lookalike?(raw) -> :numeric
      identifier?(raw) -> :ident
      true -> :invalid
    end
  end

  defp numeric_token(raw, line, col, exactness) do
    case parse_number(raw, 10, exactness) do
      {:ok, n} when is_integer(n) -> {:integer, n, {line, col}}
      {:ok, f} when is_float(f) -> {:float, f, {line, col}}
      {:ok, {:rational, _, _} = r} -> {:rational, r, {line, col}}
      :error -> raise Error, reason: {:invalid_numeric_literal, raw}, position: {line, col}
    end
  end

  defp starts_with_arrow?(<<?-, ?>, _::binary>>), do: true
  defp starts_with_arrow?(_), do: false

  # An atom "looks numeric" if its first non-sign byte is a digit or '.'.
  defp numeric_lookalike?(<<c, _::binary>>) when c in ?0..?9, do: true
  defp numeric_lookalike?(<<?., c, _::binary>>) when c in ?0..?9, do: true
  defp numeric_lookalike?(<<s, c, _::binary>>) when s in [?+, ?-] and c in ?0..?9, do: true

  defp numeric_lookalike?(<<s, ?., c, _::binary>>) when s in [?+, ?-] and c in ?0..?9, do: true

  defp numeric_lookalike?(_), do: false

  # Try to recognise `<real>+<ureal>i`, `<real>-<ureal>i`, `<real>+i`,
  # `<real>-i`, or `<real>@<real>`. Returns either:
  #
  #   * `{real_raw, imag_raw}` — both halves as raw decimal strings
  #     ready to feed back through `parse_number/3`
  #   * `{:polar, mag_raw, ang_raw}` — polar form, converted to
  #     rectangular by the token-builder
  #   * `:no_match` — atom is not a complex literal
  #
  # `+i` / `-i` are handled as integer-shortcuts at the `atom_kind/2`
  # level so they don't need to round-trip through this scanner.
  defp complex_atom_parts(raw) do
    if String.ends_with?(raw, "i"), do: rectangular_split(raw), else: polar_split(raw)
  end

  # Split `<real><sign><imag>i` at the imaginary-half sign. We scan
  # from the right so an interior sign in either half's exponent
  # (e.g. `1.0e-3+2i`) does not get mis-identified as the splitter.
  # `<real>+i` / `<real>-i` collapse to imag = ±1.
  defp rectangular_split(raw) do
    body = binary_part(raw, 0, byte_size(raw) - 1)

    case find_imag_sign(body) do
      :no_match -> :no_match
      {real_raw, imag_raw} -> classify_rectangular_split(real_raw, imag_raw)
    end
  end

  defp classify_rectangular_split(real_raw, imag_raw) when imag_raw in ["", "+", "-"],
    do: wrap_unit_imag(real_raw, imag_raw)

  defp classify_rectangular_split("", imag_raw) do
    if numeric_part_valid?(imag_raw), do: {"0", imag_raw}, else: :no_match
  end

  defp classify_rectangular_split(real_raw, imag_raw) do
    if numeric_part_valid?(real_raw) and numeric_part_valid?(imag_raw) do
      {real_raw, imag_raw}
    else
      :no_match
    end
  end

  defp wrap_unit_imag("", imag_raw), do: {0, unit_imag_sign(imag_raw)}

  defp wrap_unit_imag(real_raw, imag_raw) do
    if numeric_part_valid?(real_raw),
      do: {real_raw, unit_imag_sign(imag_raw)},
      else: :no_match
  end

  defp unit_imag_sign("-"), do: -1
  defp unit_imag_sign(_), do: 1

  # Walk `body` from the right, returning the position of the
  # `+` / `-` that separates the real and imaginary halves. Skips a
  # sign that immediately follows an exponent marker (`e` / `E`).
  defp find_imag_sign(body), do: do_find_imag_sign(body, byte_size(body) - 1)

  defp do_find_imag_sign(_body, idx) when idx <= 0, do: :no_match

  defp do_find_imag_sign(body, idx) do
    c = :binary.at(body, idx)
    prev = :binary.at(body, idx - 1)

    if c in [?+, ?-] and prev not in [?e, ?E] do
      real_raw = binary_part(body, 0, idx)
      imag_raw = binary_part(body, idx, byte_size(body) - idx)
      {real_raw, imag_raw}
    else
      do_find_imag_sign(body, idx - 1)
    end
  end

  defp polar_split(raw) do
    case String.split(raw, "@", parts: 2) do
      [mag_raw, ang_raw]
      when mag_raw != "" and ang_raw != "" ->
        if numeric_part_valid?(mag_raw) and numeric_part_valid?(ang_raw) do
          {:polar, mag_raw, ang_raw}
        else
          :no_match
        end

      _ ->
        :no_match
    end
  end

  defp numeric_part_valid?(""), do: false
  defp numeric_part_valid?(s) when s in ["+inf.0", "-inf.0", "+nan.0", "-nan.0"], do: true

  defp numeric_part_valid?(s) do
    case parse_number(s, 10, :auto) do
      {:ok, _} -> true
      :error -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Dot
  # ---------------------------------------------------------------------------

  defp read_dot_token(<<?., rest::binary>> = src, line, col) do
    if dot_alone?(rest) do
      {{:dot, nil, {line, col}}, rest, col + 1}
    else
      {raw, rest, taken} = scan_atom(src, [])
      {classify_dot_atom(raw, line, col), rest, col + taken}
    end
  end

  defp dot_alone?(<<>>), do: true
  defp dot_alone?(<<c, _::binary>>) when c in @terminators, do: true
  defp dot_alone?(_), do: false

  defp classify_dot_atom("...", line, col), do: {:ident, "...", {line, col}}

  defp classify_dot_atom(raw, line, col) do
    cond do
      numeric_lookalike?(raw) -> numeric_token(raw, line, col, :auto)
      identifier?(raw) -> {:ident, raw, {line, col}}
      true -> raise Error, reason: {:invalid_token, raw}, position: {line, col}
    end
  end

  # ---------------------------------------------------------------------------
  # Number parsing
  # ---------------------------------------------------------------------------

  defp parse_number(raw, radix, exactness) do
    {sign, body} = strip_sign(raw)

    case body == "" or classify_body(body, radix) do
      true -> :error
      :rational -> parse_rational_literal(sign, body, radix, exactness)
      :real when radix != 10 -> :error
      :real -> parse_float_literal(sign, body, exactness)
      :integer -> parse_integer_literal(sign, body, radix, exactness)
    end
  end

  defp strip_sign(<<?+, rest::binary>>), do: {1, rest}
  defp strip_sign(<<?-, rest::binary>>), do: {-1, rest}
  defp strip_sign(rest), do: {1, rest}

  # `e` / `E` only mark a base-10 exponent — under base 16 they are
  # ordinary digits, so don't treat them as the float marker.
  defp classify_body(<<>>, _radix), do: :integer
  defp classify_body(<<?/, _::binary>>, _radix), do: :rational
  defp classify_body(<<?., _::binary>>, _radix), do: :real
  defp classify_body(<<c, _::binary>>, 10) when c in [?e, ?E], do: :real
  defp classify_body(<<_, rest::binary>>, radix), do: classify_body(rest, radix)

  defp parse_integer_literal(sign, body, radix, exactness) do
    if digits_in_radix?(body, radix) do
      n = sign * String.to_integer(body, radix)

      case exactness do
        :inexact -> {:ok, n / 1}
        _ -> {:ok, n}
      end
    else
      :error
    end
  end

  defp parse_rational_literal(sign, body, radix, exactness) do
    case String.split(body, "/", parts: 2) do
      [num_str, den_str]
      when num_str != "" and den_str != "" ->
        with true <- digits_in_radix?(num_str, radix),
             true <- digits_in_radix?(den_str, radix),
             den when den > 0 <- String.to_integer(den_str, radix) do
          num = sign * String.to_integer(num_str, radix)
          to_rational_token(num, den, exactness)
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp to_rational_token(num, den, :inexact), do: {:ok, num / den}

  defp to_rational_token(num, den, _), do: {:ok, Value.rational(num, den)}

  defp parse_float_literal(sign, body, exactness) do
    body =
      cond do
        String.starts_with?(body, ".") -> "0" <> body
        String.ends_with?(body, ".") -> body <> "0"
        true -> body
      end

    case Float.parse(body) do
      {f, ""} ->
        v = sign * f

        case exactness do
          :exact -> {:ok, trunc(v)}
          _ -> {:ok, v}
        end

      _ ->
        :error
    end
  end

  defp digits_in_radix?(<<>>, _radix), do: false
  defp digits_in_radix?(s, radix), do: every_byte?(s, &digit_in_radix?(&1, radix))

  defp every_byte?(<<>>, _f), do: true
  defp every_byte?(<<c, rest::binary>>, f), do: f.(c) and every_byte?(rest, f)

  defp digit_in_radix?(c, 2), do: c in ?0..?1
  defp digit_in_radix?(c, 8), do: c in ?0..?7
  defp digit_in_radix?(c, 10), do: c in ?0..?9
  defp digit_in_radix?(c, 16), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  defp all_hex_digits?(s), do: every_byte?(s, &digit_in_radix?(&1, 16))

  # The BEAM cannot represent IEEE-754 non-finite floats as `float()`
  # values; they are modelled as a distinct tagged value in `Schooner.Value`.
  defp special_float("+inf.0"), do: {:float_special, :pos_inf}
  defp special_float("-inf.0"), do: {:float_special, :neg_inf}
  defp special_float("+nan.0"), do: {:float_special, :nan}
  defp special_float("-nan.0"), do: {:float_special, :nan}

  # ---------------------------------------------------------------------------
  # Identifier classification
  # ---------------------------------------------------------------------------

  defp identifier?(""), do: false

  defp identifier?(<<c::utf8, rest::binary>>) do
    identifier_start?(c) and identifier_subsequents?(rest)
  end

  defp identifier_subsequents?(<<>>), do: true

  defp identifier_subsequents?(<<c::utf8, rest::binary>>) do
    identifier_continue?(c) and identifier_subsequents?(rest)
  end

  defp identifier_start?(c) do
    c in ?a..?z or c in ?A..?Z or c >= 0x80 or
      c in [?!, ?$, ?%, ?&, ?*, ?/, ?:, ?<, ?=, ?>, ??, ?^, ?_, ?~]
  end

  defp identifier_continue?(c) do
    identifier_start?(c) or c in ?0..?9 or c in [?+, ?-, ?., ?@]
  end
end

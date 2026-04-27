defmodule Schooner.Reader do
  @moduledoc """
  Token stream → datum AST.

  Consumes the flat token stream from `Schooner.Lexer` and produces a list
  of `Schooner.Value` terms, one per top-level datum. Reader macros are
  desugared into the canonical cons-cell forms so the rest of the
  pipeline only ever deals with core data:

      'x   → (quote x)
      `x   → (quasiquote x)
      ,x   → (unquote x)
      ,@x  → (unquote-splicing x)

  Dotted pairs, vector literals, and bytevector literals are recognised.
  Datum comments (`#;`) skip exactly one following datum and may stack.

  Errors are raised as `Schooner.Reader.Error` with a structured reason
  and source position so downstream tooling can quote the offending input
  back to the user.

  ## Positioned output

  `read_string_positioned/1` returns each top-level datum paired with a
  parallel "position tree" mirroring the datum's spine. Each position
  tree node carries the `{line, column}` of the datum's first token.
  Use the helpers `position_of/1`, `list_positions/1` and
  `vector_positions/1` to walk the tree alongside the datum.
  """

  alias Schooner.Lexer
  alias Schooner.Reader.Error
  alias Schooner.Value

  @typedoc """
  A position tree mirrors the spine of a datum.

    * `{:atom, pos}` — non-compound datum (symbol, number, string, char,
      bool, `:null`, etc.) or the terminating `:null` of a proper list.
    * `{:pair, pos, car_tree, cdr_tree}` — cons cell. `pos` is the
      position of the opening `(` of the surrounding list.
    * `{:vector, pos, [item_tree]}` — `#(...)` literal.
    * `{:bytevector, pos}` — `#u8(...)` literal; bytes are atoms with no
      individual sub-trees.
  """
  @type pos_tree ::
          {:atom, Lexer.position()}
          | {:pair, Lexer.position(), pos_tree(), pos_tree()}
          | {:vector, Lexer.position(), [pos_tree()]}
          | {:bytevector, Lexer.position()}

  @doc "Read a binary of source into a list of top-level datums."
  @spec read_string(binary()) :: [Value.t()]
  def read_string(source) when is_binary(source) do
    source |> Lexer.tokenise() |> read_tokens()
  end

  @doc "Read a list of lexer tokens into a list of top-level datums."
  @spec read_tokens([Lexer.token()]) :: [Value.t()]
  def read_tokens(tokens) when is_list(tokens) do
    tokens |> do_read_all([]) |> Enum.map(fn {datum, _pos} -> datum end)
  end

  @doc """
  Read a binary of source into a list of `{datum, pos_tree}` pairs, one
  per top-level datum. The position tree mirrors the spine of the datum
  so callers can quote the source location of any sub-form.
  """
  @spec read_string_positioned(binary()) :: [{Value.t(), pos_tree()}]
  def read_string_positioned(source) when is_binary(source) do
    source |> Lexer.tokenise() |> do_read_all([])
  end

  # ---------------------------------------------------------------------------
  # Position-tree helpers
  # ---------------------------------------------------------------------------

  @doc "Start position of the datum the position tree describes."
  @spec position_of(pos_tree()) :: Lexer.position()
  def position_of({:atom, pos}), do: pos
  def position_of({:pair, pos, _, _}), do: pos
  def position_of({:vector, pos, _}), do: pos
  def position_of({:bytevector, pos}), do: pos

  @doc """
  Walk a list-shaped position tree into a list of element trees, one per
  cons cell in the proper-list spine. Mirrors `Schooner.Value.to_list/1`.
  Raises `ArgumentError` when the tree describes an improper or non-list
  datum.
  """
  @spec list_positions(pos_tree()) :: [pos_tree()]
  def list_positions({:atom, _}), do: []
  def list_positions({:pair, _, car, cdr}), do: [car | list_positions(cdr)]

  def list_positions(other) do
    raise ArgumentError, "expected a list position tree, got #{inspect(other)}"
  end

  @doc """
  Element-wise position trees of a vector position tree.
  """
  @spec vector_positions(pos_tree()) :: [pos_tree()]
  def vector_positions({:vector, _, items}), do: items

  def vector_positions(other) do
    raise ArgumentError, "expected a vector position tree, got #{inspect(other)}"
  end

  # ---------------------------------------------------------------------------
  # Top-level driver
  # ---------------------------------------------------------------------------

  defp do_read_all(tokens, acc) do
    case read_one(tokens) do
      :eof -> Enum.reverse(acc)
      {:ok, datum, pos, rest} -> do_read_all(rest, [{datum, pos} | acc])
    end
  end

  # `read_one/1` is the only place that yields `:eof`. Every interior context
  # (inside a list, after a quote marker) treats `:eof` as a structured
  # error specific to that context.
  defp read_one(tokens) do
    case skip_datum_comments(tokens) do
      [] ->
        :eof

      tokens ->
        {datum, pos, rest} = read_datum(tokens)
        {:ok, datum, pos, rest}
    end
  end

  # ---------------------------------------------------------------------------
  # Datum comments — `#;` consumes the next datum
  # ---------------------------------------------------------------------------

  defp skip_datum_comments([{:datum_comment, _, pos} | rest]) do
    case read_one(rest) do
      :eof -> raise Error, reason: :datum_comment_at_eof, position: pos
      {:ok, _skipped, _pos, rest} -> skip_datum_comments(rest)
    end
  end

  defp skip_datum_comments(tokens), do: tokens

  # ---------------------------------------------------------------------------
  # Single-datum dispatch
  # ---------------------------------------------------------------------------

  defp read_datum([{:integer, n, pos} | rest]), do: {n, {:atom, pos}, rest}
  defp read_datum([{:float, f, pos} | rest]), do: {f, {:atom, pos}, rest}
  defp read_datum([{:bool, b, pos} | rest]), do: {Value.bool(b), {:atom, pos}, rest}
  defp read_datum([{:string, s, pos} | rest]), do: {Value.string(s), {:atom, pos}, rest}
  defp read_datum([{:char, cp, pos} | rest]), do: {Value.char(cp), {:atom, pos}, rest}
  defp read_datum([{:ident, name, pos} | rest]), do: {Value.symbol(name), {:atom, pos}, rest}

  defp read_datum([{:quote, _, pos} | rest]), do: read_quoted("quote", rest, pos)
  defp read_datum([{:quasiquote, _, pos} | rest]), do: read_quoted("quasiquote", rest, pos)
  defp read_datum([{:unquote, _, pos} | rest]), do: read_quoted("unquote", rest, pos)

  defp read_datum([{:unquote_splicing, _, pos} | rest]) do
    read_quoted("unquote-splicing", rest, pos)
  end

  defp read_datum([{:lparen, _, pos} | rest]), do: read_list(rest, pos)
  defp read_datum([{:vector_open, _, pos} | rest]), do: read_vector(rest, pos)
  defp read_datum([{:bytevector_open, _, pos} | rest]), do: read_bytevector(rest, pos)

  defp read_datum([{:rparen, _, pos} | _]) do
    raise Error, reason: :unexpected_close_paren, position: pos
  end

  defp read_datum([{:dot, _, pos} | _]) do
    raise Error, reason: :unexpected_dot, position: pos
  end

  # ---------------------------------------------------------------------------
  # Quote forms — desugar to `(<sym> <datum>)`
  # ---------------------------------------------------------------------------

  defp read_quoted(sym_name, tokens, pos) do
    case read_one(tokens) do
      :eof ->
        raise Error, reason: {:unexpected_eof_after, sym_name}, position: pos

      {:ok, datum, inner_pos, rest} ->
        value = Value.list([Value.symbol(sym_name), datum])

        pos_tree =
          {:pair, pos, {:atom, pos}, {:pair, pos, inner_pos, {:atom, pos}}}

        {value, pos_tree, rest}
    end
  end

  # ---------------------------------------------------------------------------
  # Lists — proper `(a b c)` and dotted `(a b . c)`
  # ---------------------------------------------------------------------------

  defp read_list(tokens, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        {:null, {:atom, start}, rest}

      [{:dot, _, pos} | _] ->
        raise Error, reason: :dot_at_list_start, position: pos

      [] ->
        raise Error, reason: :unterminated_list, position: start

      tokens ->
        {datum, datum_pos, rest} = read_datum(tokens)
        read_list_tail(rest, [datum], [datum_pos], start)
    end
  end

  defp read_list_tail(tokens, dacc, pacc, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        datum = Value.list(Enum.reverse(dacc))
        pos_tree = build_list_pos(Enum.reverse(pacc), {:atom, start}, start)
        {datum, pos_tree, rest}

      [{:dot, _, dot_pos} | rest] ->
        finish_dotted_list(rest, dacc, pacc, dot_pos, start)

      [] ->
        raise Error, reason: :unterminated_list, position: start

      tokens ->
        {datum, datum_pos, rest} = read_datum(tokens)
        read_list_tail(rest, [datum | dacc], [datum_pos | pacc], start)
    end
  end

  defp finish_dotted_list(tokens, dacc, pacc, dot_pos, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | _] ->
        raise Error, reason: :missing_tail_after_dot, position: dot_pos

      [] ->
        raise Error, reason: :missing_tail_after_dot, position: dot_pos

      tail_tokens ->
        {tail, tail_pos, rest} = read_datum(tail_tokens)

        case skip_datum_comments(rest) do
          [{:rparen, _, _} | rest2] ->
            datum = Value.improper_list(Enum.reverse(dacc), tail)
            pos_tree = build_list_pos(Enum.reverse(pacc), tail_pos, start)
            {datum, pos_tree, rest2}

          [{_, _, pos} | _] ->
            raise Error, reason: :extra_after_dot, position: pos

          [] ->
            raise Error, reason: :unterminated_list, position: start
        end
    end
  end

  defp build_list_pos([], tail_pos, _start), do: tail_pos

  defp build_list_pos([head | rest], tail_pos, start) do
    {:pair, start, head, build_list_pos(rest, tail_pos, start)}
  end

  # ---------------------------------------------------------------------------
  # Vectors — `#(...)`
  # ---------------------------------------------------------------------------

  defp read_vector(tokens, start), do: do_read_vector(tokens, [], [], start)

  defp do_read_vector(tokens, dacc, pacc, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        datum = Value.vector(Enum.reverse(dacc))
        {datum, {:vector, start, Enum.reverse(pacc)}, rest}

      [{:dot, _, pos} | _] ->
        raise Error, reason: :dot_in_vector, position: pos

      [] ->
        raise Error, reason: :unterminated_vector, position: start

      tokens ->
        {datum, datum_pos, rest} = read_datum(tokens)
        do_read_vector(rest, [datum | dacc], [datum_pos | pacc], start)
    end
  end

  # ---------------------------------------------------------------------------
  # Bytevectors — `#u8(...)`, only integer tokens in 0..255
  # ---------------------------------------------------------------------------

  defp read_bytevector(tokens, start), do: do_read_bytevector(tokens, [], start)

  defp do_read_bytevector(tokens, acc, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        {Value.bytevector(Enum.reverse(acc)), {:bytevector, start}, rest}

      [{:integer, n, pos} | rest] ->
        if n in 0..255 do
          do_read_bytevector(rest, [n | acc], start)
        else
          raise Error, reason: {:invalid_byte, n}, position: pos
        end

      [] ->
        raise Error, reason: :unterminated_bytevector, position: start

      [{tag, _, pos} | _] ->
        raise Error, reason: {:invalid_in_bytevector, tag}, position: pos
    end
  end
end

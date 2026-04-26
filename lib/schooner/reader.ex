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
  """

  alias Schooner.Lexer
  alias Schooner.Reader.Error
  alias Schooner.Value

  @doc "Read a binary of source into a list of top-level datums."
  @spec read_string(binary()) :: [Value.t()]
  def read_string(source) when is_binary(source) do
    source |> Lexer.tokenise() |> read_tokens()
  end

  @doc "Read a list of lexer tokens into a list of top-level datums."
  @spec read_tokens([Lexer.token()]) :: [Value.t()]
  def read_tokens(tokens) when is_list(tokens) do
    do_read_all(tokens, [])
  end

  # ---------------------------------------------------------------------------
  # Top-level driver
  # ---------------------------------------------------------------------------

  defp do_read_all(tokens, acc) do
    case read_one(tokens) do
      :eof -> Enum.reverse(acc)
      {:ok, datum, rest} -> do_read_all(rest, [datum | acc])
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
        {datum, rest} = read_datum(tokens)
        {:ok, datum, rest}
    end
  end

  # ---------------------------------------------------------------------------
  # Datum comments — `#;` consumes the next datum
  # ---------------------------------------------------------------------------

  defp skip_datum_comments([{:datum_comment, _, pos} | rest]) do
    case read_one(rest) do
      :eof -> raise Error, reason: :datum_comment_at_eof, position: pos
      {:ok, _skipped, rest} -> skip_datum_comments(rest)
    end
  end

  defp skip_datum_comments(tokens), do: tokens

  # ---------------------------------------------------------------------------
  # Single-datum dispatch
  # ---------------------------------------------------------------------------

  defp read_datum([{:integer, n, _} | rest]), do: {n, rest}
  defp read_datum([{:float, f, _} | rest]), do: {f, rest}
  defp read_datum([{:bool, b, _} | rest]), do: {Value.bool(b), rest}
  defp read_datum([{:string, s, _} | rest]), do: {Value.string(s), rest}
  defp read_datum([{:char, cp, _} | rest]), do: {Value.char(cp), rest}
  defp read_datum([{:ident, name, _} | rest]), do: {Value.symbol(name), rest}

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

      {:ok, datum, rest} ->
        {Value.list([Value.symbol(sym_name), datum]), rest}
    end
  end

  # ---------------------------------------------------------------------------
  # Lists — proper `(a b c)` and dotted `(a b . c)`
  # ---------------------------------------------------------------------------

  defp read_list(tokens, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        {:null, rest}

      [{:dot, _, pos} | _] ->
        raise Error, reason: :dot_at_list_start, position: pos

      [] ->
        raise Error, reason: :unterminated_list, position: start

      tokens ->
        {datum, rest} = read_datum(tokens)
        read_list_tail(rest, [datum], start)
    end
  end

  defp read_list_tail(tokens, acc, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        {Value.list(Enum.reverse(acc)), rest}

      [{:dot, _, dot_pos} | rest] ->
        finish_dotted_list(rest, acc, dot_pos, start)

      [] ->
        raise Error, reason: :unterminated_list, position: start

      tokens ->
        {datum, rest} = read_datum(tokens)
        read_list_tail(rest, [datum | acc], start)
    end
  end

  defp finish_dotted_list(tokens, acc, dot_pos, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | _] ->
        raise Error, reason: :missing_tail_after_dot, position: dot_pos

      [] ->
        raise Error, reason: :missing_tail_after_dot, position: dot_pos

      tail_tokens ->
        {tail, rest} = read_datum(tail_tokens)

        case skip_datum_comments(rest) do
          [{:rparen, _, _} | rest2] ->
            {Value.improper_list(Enum.reverse(acc), tail), rest2}

          [{_, _, pos} | _] ->
            raise Error, reason: :extra_after_dot, position: pos

          [] ->
            raise Error, reason: :unterminated_list, position: start
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Vectors — `#(...)`
  # ---------------------------------------------------------------------------

  defp read_vector(tokens, start), do: do_read_vector(tokens, [], start)

  defp do_read_vector(tokens, acc, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        {Value.vector(Enum.reverse(acc)), rest}

      [{:dot, _, pos} | _] ->
        raise Error, reason: :dot_in_vector, position: pos

      [] ->
        raise Error, reason: :unterminated_vector, position: start

      tokens ->
        {datum, rest} = read_datum(tokens)
        do_read_vector(rest, [datum | acc], start)
    end
  end

  # ---------------------------------------------------------------------------
  # Bytevectors — `#u8(...)`, only integer tokens in 0..255
  # ---------------------------------------------------------------------------

  defp read_bytevector(tokens, start), do: do_read_bytevector(tokens, [], start)

  defp do_read_bytevector(tokens, acc, start) do
    case skip_datum_comments(tokens) do
      [{:rparen, _, _} | rest] ->
        {Value.bytevector(Enum.reverse(acc)), rest}

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

defmodule Schooner.REPL.Input do
  @moduledoc false

  # What `mix schooner.repl` reads: whether an entry is complete, and
  # how far to indent the next line of one that isn't.
  #
  # Indentation follows `Schooner.Pretty`, so code typed into the REPL
  # is laid out the way `,expand` prints it: the body of a body form
  # (`define`, `lambda`, the `let` family, ...) two columns in from its
  # opening parenthesis, and its distinguished arguments, when they
  # are still being typed on later lines, four in; the arguments of a
  # call lined up under the first; and the items of a list that isn't
  # a call, such as `let` bindings or quoted data, under the first
  # item.

  alias Schooner.Lexer
  alias Schooner.Pretty
  alias Schooner.Reader
  alias Schooner.REPL.Cells

  # Meta-commands whose argument is Scheme source, which may run over
  # several lines.
  @commands_with_source ["expand", "time"]

  # Reader and lexer errors that mean the source stopped before a datum
  # ended, so more lines may finish it.
  @unfinished [
    :unterminated_list,
    :unterminated_vector,
    :unterminated_bytevector,
    :unterminated_string,
    :unterminated_block_comment,
    :unterminated_bar_identifier,
    :datum_comment_at_eof
  ]

  @doc """
  Whether `text` is a whole entry: blank, a meta-command, or source
  that reads without running out. Source that fails to read for any
  other reason is complete, so the error is reported rather than
  waited on.
  """
  @spec complete?(binary()) :: boolean()
  def complete?(text) do
    case command(text) do
      {name, source} when name in @commands_with_source -> source_complete?(source)
      {_name, _args} -> true
      nil -> source_complete?(text)
    end
  end

  @doc """
  `{name, args}` when `text` is a meta-command such as `,env car`, and
  `nil` otherwise. A comma followed by anything but a letter, as in
  `,x` or `,(f)`, is a comma.
  """
  @spec command(binary()) :: {binary(), binary()} | nil
  def command(text) do
    case Regex.run(~r/\A\s*,([[:alpha:]][^\s()";]*)(.*)\z/su, text) do
      [_, name, args] -> {name, args}
      nil -> nil
    end
  end

  defp source_complete?(source) do
    Reader.read_string(source)
    true
  rescue
    e in [Lexer.Error, Reader.Error] -> not unfinished?(e.reason, source)
  end

  defp unfinished?(reason, _source) when reason in @unfinished, do: true
  defp unfinished?({:unexpected_eof_after, _}, _source), do: true
  # `(a .` with nothing after the dot yet, but not `(a . )`.
  defp unfinished?(:missing_tail_after_dot, source), do: scan(source).stack != []
  defp unfinished?(_reason, _source), do: false

  @doc """
  The column a line typed after `text` should start at, or `nil` when
  `text` ends inside a string, a `|...|` identifier or a block
  comment, where leading spaces would change what was typed.
  """
  @spec indentation(binary()) :: non_neg_integer() | nil
  def indentation(text) do
    case scan(text) do
      %{mode: mode} when mode in [:string, :bar, :block_comment] -> nil
      %{stack: []} -> 0
      %{stack: [frame | _]} -> frame_indentation(frame)
    end
  end

  # Data, such as a quoted list or a vector, lines its items up.
  defp frame_indentation(%{data?: true} = frame), do: items_column(frame)

  defp frame_indentation(%{head: %{symbol: symbol}} = frame) when is_binary(symbol) do
    # `body_count/2` looks only at whether the first argument is a
    # symbol, which makes a `let` named.
    args = if frame.first_arg && frame.first_arg.symbol?, do: [{:sym, ""}], else: []

    case Pretty.body_count(symbol, args) do
      nil when frame.first_arg != nil -> frame.first_arg.column
      nil -> frame.items_column
      n when frame.count - 1 >= n -> frame.column + 2
      _distinguished -> frame.column + 4
    end
  end

  defp frame_indentation(frame), do: items_column(frame)

  defp items_column(%{head: %{column: column}}), do: column
  defp items_column(%{items_column: column}), do: column

  # ---------------------------------------------------------------------------
  # Scanning
  # ---------------------------------------------------------------------------

  # Scan `text` far enough to know which lists are open at its end, and
  # where their first items are. Columns count graphemes from the start
  # of the line. Only the structure matters, so this is much looser
  # than the lexer: anything that isn't a delimiter, a string, a
  # comment or a `|...|` identifier is an atom.
  defp scan(text) do
    state = %{line: 0, column: 0, mode: :code, depth: 0, stack: [], prefix: nil, comments: 0}
    text |> String.graphemes() |> scan(state)
  end

  defp scan([], state), do: state

  defp scan([g | rest], %{mode: :string} = state) do
    case g do
      "\\" ->
        case rest do
          [next | rest] -> scan(rest, state |> advance("\\") |> advance(next))
          [] -> state
        end

      "\"" ->
        scan(rest, %{advance(state, g) | mode: :code})

      _ ->
        scan(rest, advance(state, g))
    end
  end

  defp scan([g | rest], %{mode: :bar} = state) do
    case g do
      "\\" ->
        case rest do
          [next | rest] -> scan(rest, state |> advance("\\") |> advance(next))
          [] -> state
        end

      "|" ->
        scan(rest, %{advance(state, g) | mode: :code})

      _ ->
        scan(rest, advance(state, g))
    end
  end

  defp scan([g | rest], %{mode: :line_comment} = state) do
    if newline?(g),
      do: scan(rest, %{advance(state, g) | mode: :code}),
      else: scan(rest, advance(state, g))
  end

  defp scan(["|", "#" | rest], %{mode: :block_comment, depth: 1} = state),
    do: scan(rest, %{advance(state, "|#") | mode: :code, depth: 0})

  defp scan(["|", "#" | rest], %{mode: :block_comment} = state),
    do: scan(rest, %{advance(state, "|#") | depth: state.depth - 1})

  defp scan(["#", "|" | rest], %{mode: :block_comment} = state),
    do: scan(rest, %{advance(state, "#|") | depth: state.depth + 1})

  defp scan([g | rest], %{mode: :block_comment} = state), do: scan(rest, advance(state, g))

  defp scan(["#", "|" | rest], state),
    do: scan(rest, %{advance(state, "#|") | mode: :block_comment, depth: 1})

  # A datum comment: the next datum isn't an item. They can stack.
  defp scan(["#", ";" | rest], state),
    do: scan(rest, %{advance(state, "#;") | comments: state.comments + 1})

  defp scan(["#", "\\", char | rest], state) do
    {atom, rest} = Enum.split_while(rest, &(not delimiter?(&1)))
    state = state |> item(nil) |> advance("#\\" <> char <> Enum.join(atom))
    scan(rest, state)
  end

  defp scan(["#", "(" | rest], state), do: scan(rest, open(state, "#(", true))

  defp scan(["#", "u", "8", "(" | rest], state), do: scan(rest, open(state, "#u8(", true))

  defp scan([g | rest], state) when g in ["(", "["], do: scan(rest, open(state, g, false))

  defp scan([g | rest], state) when g in [")", "]"] do
    state = %{advance(state, g) | prefix: nil, comments: 0}

    case state.stack do
      [_ | stack] -> scan(rest, %{state | stack: stack})
      [] -> scan(rest, state)
    end
  end

  defp scan([g | rest], state) when g in ["'", "`"],
    do: scan(rest, state |> prefix(true) |> advance(g))

  defp scan([",", "@" | rest], state), do: scan(rest, state |> prefix(false) |> advance(",@"))
  defp scan(["," | rest], state), do: scan(rest, state |> prefix(false) |> advance(","))

  defp scan(["\"" | rest], state),
    do: scan(rest, %{(state |> item(nil) |> advance("\"")) | mode: :string})

  defp scan(["|" | rest], state),
    do: scan(rest, %{(state |> item(nil) |> advance("|")) | mode: :bar})

  defp scan([";" | rest], state), do: scan(rest, %{advance(state, ";") | mode: :line_comment})

  defp scan([g | rest], state) do
    if delimiter?(g) do
      scan(rest, advance(state, g))
    else
      {atom, rest} = Enum.split_while(rest, &(not delimiter?(&1)))
      atom = Enum.join([g | atom])
      symbol = if number?(atom), do: nil, else: atom
      scan(rest, state |> item(symbol) |> advance(atom))
    end
  end

  # Open a list with the delimiter `open`. The list is an item of the
  # list around it, and is data when that one is, when it's quoted,
  # and when it's a vector or bytevector (`data?`).
  defp open(state, open, data?) do
    quoted? = match?({_, _, true}, state.prefix)
    outer_data? = match?([%{data?: true} | _], state.stack)
    column = state.column
    state = item(state, nil)

    frame = %{
      column: column,
      items_column: column + String.length(open),
      data?: data? or quoted? or outer_data?,
      count: 0,
      head: nil,
      first_arg: nil
    }

    %{advance(state, open) | stack: [frame | state.stack]}
  end

  # Count an item starting at the current position, or at the prefix
  # (`'`, `,`, ...) in front of it, in the innermost open list. A datum
  # a `#;` comments out isn't counted.
  defp item(%{comments: comments} = state, _symbol) when comments > 0,
    do: %{state | prefix: nil, comments: comments - 1}

  defp item(%{stack: []} = state, _symbol), do: %{state | prefix: nil}

  defp item(%{stack: [frame | stack]} = state, symbol) do
    {line, column} =
      case state.prefix do
        {line, column, _quoted?} -> {line, column}
        nil -> {state.line, state.column}
      end

    # A prefixed item is a list or quoted datum, not a call's head.
    symbol = if state.prefix, do: nil, else: symbol
    position = %{line: line, column: column, symbol: symbol, symbol?: symbol != nil}

    frame =
      case frame.count do
        0 -> %{frame | head: position}
        1 -> %{frame | first_arg: position}
        _ -> frame
      end

    %{state | stack: [%{frame | count: frame.count + 1} | stack], prefix: nil}
  end

  # Note a prefix, keeping the position of the first one in a run such
  # as `',x`.
  defp prefix(%{prefix: nil} = state, quoted?),
    do: %{state | prefix: {state.line, state.column, quoted?}}

  defp prefix(state, _quoted?), do: state

  defp advance(state, text) do
    if newline?(text),
      do: %{state | line: state.line + 1, column: 0},
      else: %{state | column: state.column + Cells.width(text, state.column)}
  end

  defp newline?(g), do: g in ["\n", "\r\n", "\r"]

  # The lexer's terminators, and the other whitespace.
  defp delimiter?(g),
    do:
      g in [" ", "\t", "\n", "\r\n", "\r", "\f", "(", ")", "[", "]", "{", "}", "\"", ";", "|"] or
        g in ["'", "`", ","]

  defp number?(atom), do: Regex.match?(~r/\A[+-]?\.?[0-9]|\A#[eixbodEIXBOD]/, atom)
end

defmodule Schooner.Pretty do
  @moduledoc ~S"""
  Pretty-printing for Scheme data and code, such as the forms returned
  by `Schooner.expand/3`.

  A form that fits on one line is printed on one line. A longer one is
  broken across lines and indented the way Scheme code usually is:
  the body of a `lambda`, `define`, `let` and the other binding and
  body forms is indented by two spaces, and the arguments of other
  calls are lined up under the first.

      iex> form = Schooner.Value.list([
      ...>   {:sym, "define"},
      ...>   Schooner.Value.list([{:sym, "area"}, {:sym, "r"}]),
      ...>   Schooner.Value.list([{:sym, "*"}, {:sym, "pi"}, {:sym, "r"}, {:sym, "r"}])
      ...> ])
      iex> Schooner.Pretty.format(form)
      "(define (area r) (* pi r r))"
      iex> Schooner.Pretty.format(form, width: 20)
      "(define (area r)\n  (* pi r r))"

  `(quote x)`, `(quasiquote x)`, `(unquote x)` and
  `(unquote-splicing x)` are printed as `'x`, `` `x ``, `,x` and
  `,@x`. Everything else that has a written form is printed as
  `Schooner.Value.write/1` would print it, so reading the output back
  gives a datum `equal?` to the one printed, unless it contains
  renamed identifiers (below).

  ## Renamed identifiers

  An identifier that a macro introduces is renamed during expansion,
  so it can't capture, or be captured by, an identifier of the same
  name in the code that uses the macro. By default it is printed as
  its name and a number, joined by a middle dot (`tmp·1`), so it can be
  told apart from the code's own `tmp`. With `names: :plain` it is
  printed as its name alone (`tmp`).

  A renamed identifier has no written form, so neither way of
  printing it reads back as the same identifier: `tmp·1` reads as an
  ordinary symbol with that name, which a symbol of the code's own
  could share, and `tmp` reads as the code's `tmp`. The output is for
  people to read. Don't read it back as code, because a macro's
  identifier could then capture, or be captured by, the code's own.
  """

  alias Schooner.Expander.SyntaxRules
  alias Schooner.Value

  @call_site Schooner.Eval.call_site()

  @abbreviations %{
    "quote" => "'",
    "quasiquote" => "`",
    "unquote" => ",",
    "unquote-splicing" => ",@"
  }

  # Forms whose first `n` arguments stay on the first line, with the
  # rest, their body, indented by two spaces on the lines after.
  @body_forms %{
    "begin" => 0,
    "case-lambda" => 0,
    "delay" => 0,
    "delay-force" => 0,
    "case" => 1,
    "define" => 1,
    "define-record-type" => 1,
    "define-syntax" => 1,
    "define-values" => 1,
    "guard" => 1,
    "lambda" => 1,
    "let" => 1,
    "let*" => 1,
    "let*-values" => 1,
    "let-syntax" => 1,
    "let-values" => 1,
    "letrec" => 1,
    "letrec*" => 1,
    "letrec-syntax" => 1,
    "parameterize" => 1,
    "syntax-rules" => 1,
    "unless" => 1,
    "when" => 1,
    "do" => 2
  }

  @doc ~S"""
  Format `value` as text.

  Options:

    * `:width` — the line width to fit forms in, a positive integer.
      A form that can't fit, such as a long symbol, is printed anyway.
      Defaults to 80.
    * `:names` — how to print identifiers renamed by macro expansion:
      `:marked` (the default) adds their number (`tmp·1`), and
      `:plain` prints the name alone (`tmp`).

  Values with no written form, such as procedures and the record type
  in an expanded `define-record-type`, are printed as `#<...>`.
  """
  @spec format(Value.t(), keyword()) :: binary()
  def format(value, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, width: 80, names: :marked)
    width = Keyword.fetch!(opts, :width)
    names = Keyword.fetch!(opts, :names)

    unless is_integer(width) and width > 0 do
      raise ArgumentError,
            "invalid value for :width, expected a positive integer, got: #{inspect(width)}"
    end

    unless names in [:marked, :plain] do
      raise ArgumentError,
            "invalid value for :names, expected :marked or :plain, got: #{inspect(names)}"
    end

    IO.iodata_to_binary(layout(value, 0, 0, %{width: width, names: names}))
  end

  # ---------------------------------------------------------------------------
  # Layout
  # ---------------------------------------------------------------------------

  # `value` printed starting at column `col`, and followed on its last
  # line by `trail` closing delimiters: on one line when it fits,
  # broken across lines otherwise.
  defp layout(value, col, trail, cx) do
    if col + flat_length(value, cx) + trail <= cx.width,
      do: flat(value, cx),
      else: broken(value, col, trail, cx)
  end

  defp broken([{:sym, name}, datum], col, trail, cx) when is_map_key(@abbreviations, name) do
    prefix = Map.fetch!(@abbreviations, name)
    [prefix, layout(datum, col + String.length(prefix), trail, cx)]
  end

  defp broken([_ | _] = list, col, trail, cx) do
    case split_list(list) do
      {[{:sym, name} = head | args], []} ->
        broken_form(head, body_count(name, args), args, col, trail, cx)

      {items, tail} ->
        broken_items("(", items, tail, col, trail, cx)
    end
  end

  defp broken({:vector, items}, col, trail, cx),
    do: broken_items("#(", Tuple.to_list(items), [], col, trail, cx)

  defp broken(atom, _col, _trail, cx), do: flat(atom, cx)

  # A body form: its first `n` arguments on the first line, if they fit,
  # and its body below it.
  defp broken_form(head, n, args, col, trail, cx) when is_integer(n) and length(args) >= n do
    {distinguished, body} = Enum.split(args, n)
    opening = ["(", flat(head, cx)]
    # The closing delimiters after the first line, when nothing follows it.
    first_trail = if body == [], do: trail + 1, else: 0

    [
      first_line(opening, distinguished, col, first_trail, cx),
      lines(body, col + 2, trail + 1, cx),
      ")"
    ]
  end

  # A call: the arguments lined up under the first. When the first
  # doesn't fit on one line after the head, but would on a line of its
  # own, or is an atom, each item goes on its own line instead.
  defp broken_form(head, _n, [first_arg | rest] = args, col, trail, cx) do
    opening = ["(", flat(head, cx), " "]
    arg_col = col + String.length(IO.iodata_to_binary(opening))
    arg_trail = if rest == [], do: trail + 1, else: 0
    first_length = flat_length(first_arg, cx)

    aligned? =
      arg_col + first_length + arg_trail <= cx.width or
        (compound?(first_arg) and col + 1 + first_length + arg_trail > cx.width)

    if aligned? do
      [
        opening,
        layout(first_arg, arg_col, arg_trail, cx),
        lines(rest, arg_col, trail + 1, cx),
        ")"
      ]
    else
      broken_items("(", [head | args], [], col, trail, cx)
    end
  end

  defp broken_form(head, _n, [], _col, _trail, cx), do: ["(", flat(head, cx), ")"]

  # The opening of a body form and its first arguments: on one line if
  # they fit, followed by `trail` closing delimiters, and otherwise the
  # first after the opening and the rest indented by four below it.
  defp first_line(opening, [], _col, _trail, _cx), do: opening

  defp first_line(opening, [first_arg | rest] = distinguished, col, trail, cx) do
    line = [opening, Enum.map(distinguished, &[" ", flat(&1, cx)])]

    if col + String.length(IO.iodata_to_binary(line)) + trail <= cx.width do
      line
    else
      arg_col = col + String.length(IO.iodata_to_binary(opening)) + 1
      arg_trail = if rest == [], do: trail, else: 0
      [opening, " ", layout(first_arg, arg_col, arg_trail, cx), lines(rest, col + 4, trail, cx)]
    end
  end

  # Each item on its own line, lined up after `open`.
  defp broken_items(open, [first | rest], tail, col, trail, cx) do
    item_col = col + String.length(open)

    {items_trail, tail_line} =
      case tail do
        [] -> {trail + 1, []}
        _ -> {0, ["\n", indent(item_col), ". ", layout(tail, item_col + 2, trail + 1, cx)]}
      end

    first_trail = if rest == [], do: items_trail, else: 0

    [
      open,
      layout(first, item_col, first_trail, cx),
      lines(rest, item_col, items_trail, cx),
      tail_line,
      ")"
    ]
  end

  defp broken_items(open, [], [], _col, _trail, _cx), do: [open, ")"]

  # Each of `values` on its own line at `col`, the last followed by
  # `trail` closing delimiters.
  defp lines([], _col, _trail, _cx), do: []
  defp lines([value], col, trail, cx), do: [line(value, col, trail, cx)]

  defp lines([value | rest], col, trail, cx),
    do: [line(value, col, 0, cx) | lines(rest, col, trail, cx)]

  defp line(value, col, trail, cx), do: ["\n", indent(col), layout(value, col, trail, cx)]

  defp compound?([_ | _]), do: true
  defp compound?({:vector, _}), do: true
  defp compound?(_), do: false

  defp flat_length(value, cx), do: value |> flat(cx) |> IO.iodata_to_binary() |> String.length()

  defp indent(n), do: :binary.copy(" ", n)

  defp body_count(name, args) do
    case {SyntaxRules.split_marks(name), args} do
      # Named `let`: the name and the bindings.
      {{"let", _}, [{:sym, _} | _]} -> 2
      {{base, _}, _} -> Map.get(@body_forms, base)
    end
  end

  # ---------------------------------------------------------------------------
  # One-line rendering
  # ---------------------------------------------------------------------------

  defp flat({:sym, name}, cx), do: symbol(name, cx)

  defp flat([{:sym, name}, datum], cx) when is_map_key(@abbreviations, name),
    do: [Map.fetch!(@abbreviations, name), flat(datum, cx)]

  defp flat([_ | _] = list, cx) do
    {items, tail} = split_list(list)
    body = items |> Enum.map(&flat(&1, cx)) |> Enum.intersperse(" ")

    case tail do
      [] -> ["(", body, ")"]
      _ -> ["(", body, " . ", flat(tail, cx), ")"]
    end
  end

  defp flat({:vector, items}, cx) do
    body = items |> Tuple.to_list() |> Enum.map(&flat(&1, cx)) |> Enum.intersperse(" ")
    ["#(", body, ")"]
  end

  # The type identity an expanded `define-record-type` embeds in the
  # procedures it defines.
  defp flat({:record_type, name, _id}, cx), do: ["#<record-type ", symbol(name, cx), ">"]

  # The placeholder `Schooner.Debug`'s macros pass for the location of
  # their use.
  defp flat(@call_site, _cx), do: "#<call-site>"

  defp flat(value, _cx), do: Value.write_iodata(value)

  # A name of the script's own that looks like a renamed one is quoted,
  # so the two can't be confused.
  defp symbol(name, cx) do
    case SyntaxRules.split_marks(name) do
      {_base, []} -> write_symbol(name, cx.names == :marked and String.contains?(name, "·"))
      {base, _marks} when cx.names == :plain -> write_symbol(base, false)
      {base, marks} -> write_symbol(Enum.join([base | marks], "·"), false)
    end
  end

  # `name` as `Value.write/1` writes it, quoted when `quote?` or when it
  # starts with `@`, which would otherwise not read back (and after a
  # `,` would read as `,@`). A quoted name reads back the same.
  defp write_symbol(name, quote?) do
    written = Value.write_iodata({:sym, name})

    if bare?(written) and (quote? or String.starts_with?(name, "@")),
      do: ["|", written, "|"],
      else: written
  end

  defp bare?([?| | _]), do: false
  defp bare?(_written), do: true

  defp split_list(list), do: split_list(list, [])
  defp split_list([h | t], acc), do: split_list(t, [h | acc])
  defp split_list(tail, acc), do: {Enum.reverse(acc), tail}
end

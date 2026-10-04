defmodule Schooner.REPL.Editor do
  @moduledoc false

  # The line editor `mix schooner.repl` uses in a terminal: an entry of
  # one or more lines, edited a key at a time and redrawn as a whole.
  #
  # Enter submits the entry when it is complete and the cursor is at
  # its end. Otherwise it breaks the line, and indents the new one as
  # `Schooner.REPL.Input.indentation/1` says, so code lines up as it is
  # typed. Tab re-indents the current line the same way.
  #
  # The editor is pure: `key/3` takes the editor and a key and returns
  # what to do, the next editor and the text to write to the terminal.
  # A key is one character, or a whole escape sequence: `feed/2` splits
  # raw input into keys.
  #
  # Keys:
  #
  #   * Enter: submit or break the line (above). In a bracketed paste,
  #     a newline breaks the line and is never indented or submitted.
  #   * Tab: re-indent the current line.
  #   * Left, Right, Ctrl-B, Ctrl-F: move a character. Alt-B, Alt-F,
  #     Ctrl-Left, Ctrl-Right: move a word.
  #   * Home, End, Ctrl-A, Ctrl-E: move to the start or end of the line.
  #   * Up, Down, Ctrl-P, Ctrl-N: move a line within the entry, or past
  #     its first or last line, through the history of entries.
  #   * Backspace, Delete: delete a character, joining lines at the
  #     edges. Ctrl-D deletes too, but on an empty entry is end of input.
  #   * Ctrl-K, Ctrl-U: delete to the end or the start of the line.
  #     Ctrl-W, Alt-Backspace: delete the word before the cursor.
  #   * Ctrl-L: clear the screen.
  #   * Ctrl-C: discard the entry.

  alias Schooner.REPL.Input

  @prompt "schooner> "

  # Code points a terminal shows two cells wide.
  @wide [
    0x1100..0x115F,
    0x2E80..0x303E,
    0x3041..0x33FF,
    0x3400..0x4DBF,
    0x4E00..0x9FFF,
    0xA000..0xA4CF,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE30..0xFE4F,
    0xFF00..0xFF60,
    0xFFE0..0xFFE6,
    0x1F300..0x1F64F,
    0x1F900..0x1F9FF,
    0x20000..0x3FFFD
  ]
  @continuation "     ...> "

  defstruct lines: [""],
            row: 0,
            col: 0,
            # The screen row of the cursor, counted from the entry's
            # first, as last drawn.
            screen_row: 0,
            width: 80,
            history: [],
            # The position in `history` being shown, and the entry that
            # was being edited before moving into the history.
            history_index: nil,
            draft: nil,
            paste?: false,
            # Whether the last key pasted was a carriage return, whose
            # line feed, if one follows, is part of the same newline.
            paste_cr?: false

  @type t :: %__MODULE__{}
  @type action :: :continue | {:submit, binary()} | :eof

  @doc "The prompt for an entry's first line."
  def prompt, do: @prompt

  @doc "The prompt for an entry's later lines, as wide as `prompt/0`."
  def continuation, do: @continuation

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{width: Keyword.get(opts, :width, 80)}

  @doc "Start a new, empty entry, returning the editor and the prompt."
  @spec start(t()) :: {t(), iodata()}
  def start(editor) do
    editor = %{
      editor
      | lines: [""],
        row: 0,
        col: 0,
        screen_row: 0,
        history_index: nil,
        draft: nil,
        paste?: false,
        paste_cr?: false
    }

    {editor, @prompt}
  end

  @doc "The entry's text."
  @spec text(t()) :: binary()
  def text(%__MODULE__{lines: lines}), do: Enum.join(lines, "\n")

  @doc """
  Split `data`, raw terminal input, into keys, given what is left
  over from the last call: an escape sequence can arrive in pieces.
  Returns the keys and what is left over now.
  """
  @spec feed(binary(), binary()) :: {[binary()], binary()}
  def feed(pending, data), do: split_keys(pending <> data, [])

  defp split_keys("", acc), do: {Enum.reverse(acc), ""}

  defp split_keys(<<"\e", rest::binary>> = data, acc) do
    case escape(rest) do
      {:ok, sequence, rest} -> split_keys(rest, ["\e" <> sequence | acc])
      :incomplete -> {Enum.reverse(acc), data}
    end
  end

  defp split_keys(data, acc) do
    case String.next_grapheme(data) do
      {key, rest} -> split_keys(rest, [key | acc])
      nil -> {Enum.reverse(acc), data}
    end
  end

  # The rest of an escape sequence: a CSI sequence (`[` then parameters
  # then a final byte), an SS3 sequence (`O` and a letter), or Alt and a
  # key.
  defp escape(""), do: :incomplete

  defp escape(<<"[", rest::binary>>) do
    case Regex.run(~r/\A[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/, rest) do
      [sequence] ->
        size = byte_size(sequence)
        <<_::binary-size(size), rest::binary>> = rest
        {:ok, "[" <> sequence, rest}

      nil ->
        if Regex.match?(~r/\A[\x20-\x3f]*\z/, rest), do: :incomplete, else: {:ok, "[", rest}
    end
  end

  defp escape(<<"O">>), do: :incomplete
  defp escape(<<"O", c, rest::binary>>), do: {:ok, <<"O", c>>, rest}

  defp escape(rest) do
    {key, rest} = String.next_grapheme(rest)
    {:ok, key, rest}
  end

  @doc """
  Apply `key` to the entry. `width` is the terminal's width in columns.
  Returns the action, the editor and the output that redraws the entry.
  """
  @spec key(t(), binary(), pos_integer()) :: {action(), t(), iodata()}
  def key(editor, key, width) do
    editor = %{editor | width: max(width, 1)}

    case handle(editor, key) do
      {:submit, editor} -> submit(editor)
      {:eof, editor} -> {:eof, editor, [move_to_end(editor), "\n"]}
      {:interrupt, editor} -> interrupt(editor)
      {:clear, editor} -> redraw(%{editor | screen_row: 0}, "\e[H\e[2J")
      {:moved, editor} -> redraw(editor, [])
      :ignore -> {:continue, editor, []}
    end
  end

  defp redraw(editor, prefix) do
    {editor, output} = draw(editor, editor.row, editor.col)
    {:continue, editor, [prefix, output]}
  end

  # The REPL starts the next entry, with `start/1`, once it has written
  # the result.
  defp submit(editor) do
    text = text(editor)
    {{:submit, text}, remember(editor, text), [move_to_end(editor), "\n"]}
  end

  defp interrupt(editor) do
    output = [move_to_end(editor), "^C\n"]
    {editor, prompt} = start(editor)
    {:continue, editor, [output, prompt]}
  end

  # Add a submitted entry to the history, unless it is blank or repeats
  # the last one.
  defp remember(editor, text) do
    cond do
      String.trim(text) == "" -> editor
      match?([^text | _], editor.history) -> editor
      true -> %{editor | history: [text | editor.history]}
    end
  end

  # ---------------------------------------------------------------------------
  # Keys
  # ---------------------------------------------------------------------------

  defp handle(editor, "\e[200~"), do: {:moved, %{editor | paste?: true, paste_cr?: false}}
  defp handle(editor, "\e[201~"), do: {:moved, %{editor | paste?: false}}

  # Pasted text goes in as it is. The terminal hands over a CRLF
  # newline one character at a time, so a line feed straight after a
  # carriage return is dropped.
  defp handle(%{paste?: true, paste_cr?: true} = editor, "\n"),
    do: {:moved, %{editor | paste_cr?: false}}

  defp handle(%{paste?: true, paste_cr?: true} = editor, key),
    do: handle(%{editor | paste_cr?: false}, key)

  defp handle(%{paste?: true} = editor, key) when key in ["\r", "\n", "\r\n"],
    do: {:moved, %{break_line(editor, nil) | paste_cr?: key == "\r"}}

  defp handle(%{paste?: true} = editor, "\t"), do: {:moved, insert(editor, "\t")}

  defp handle(editor, key) when key in ["\r", "\n", "\r\n"], do: enter(editor)
  defp handle(editor, "\t"), do: {:moved, reindent(editor)}
  defp handle(editor, key) when key in ["\x7f", "\b"], do: {:moved, backspace(editor)}
  defp handle(editor, "\e[3~"), do: {:moved, delete(editor)}

  defp handle(editor, "\x04") do
    if text(editor) == "", do: {:eof, editor}, else: {:moved, delete(editor)}
  end

  defp handle(editor, "\x03"), do: {:interrupt, editor}
  defp handle(editor, "\x0c"), do: {:clear, editor}

  defp handle(editor, key) when key in ["\e[D", "\x02"], do: {:moved, left(editor)}
  defp handle(editor, key) when key in ["\e[C", "\x06"], do: {:moved, right(editor)}

  defp handle(editor, key) when key in ["\eb", "\e[1;5D", "\e[1;3D"],
    do: {:moved, word_left(editor)}

  defp handle(editor, key) when key in ["\ef", "\e[1;5C", "\e[1;3C"],
    do: {:moved, word_right(editor)}

  defp handle(editor, key) when key in ["\e[H", "\eOH", "\e[1~", "\e[7~", "\x01"],
    do: {:moved, %{editor | col: 0}}

  defp handle(editor, key) when key in ["\e[F", "\eOF", "\e[4~", "\e[8~", "\x05"],
    do: {:moved, %{editor | col: line_length(editor)}}

  defp handle(editor, key) when key in ["\e[A", "\x10"], do: {:moved, up(editor)}
  defp handle(editor, key) when key in ["\e[B", "\x0e"], do: {:moved, down(editor)}

  defp handle(editor, "\x0b") do
    {before, _after} = split_line(editor)
    {:moved, put_line(editor, before)}
  end

  defp handle(editor, "\x15") do
    {_before, after_} = split_line(editor)
    {:moved, %{put_line(editor, after_) | col: 0}}
  end

  defp handle(editor, key) when key in ["\x17", "\e\x7f", "\e\b"] do
    {before, after_} = split_line(editor)
    kept = before |> String.graphemes() |> drop_word_back() |> Enum.join()
    {:moved, %{put_line(editor, kept <> after_) | col: String.length(kept)}}
  end

  defp handle(editor, key) do
    if printable?(key), do: {:moved, insert(editor, key)}, else: :ignore
  end

  defp printable?(<<"\e", _::binary>>), do: false
  defp printable?(<<c::utf8, _::binary>>) when c < 0x20 or c == 0x7F, do: false
  defp printable?(_key), do: true

  defp enter(editor) do
    if at_end?(editor) and Input.complete?(text(editor)) do
      {:submit, editor}
    else
      {before, _after} = text_before_cursor(editor)
      {:moved, break_line(editor, Input.indentation(before))}
    end
  end

  # Whether only whitespace follows the cursor.
  defp at_end?(%{lines: lines, row: row} = editor) do
    {_before, after_} = split_line(editor)
    row == length(lines) - 1 and String.trim(after_) == ""
  end

  # Break the line at the cursor. With an `indent`, drop the
  # whitespace around the cursor and start the new line with `indent`
  # spaces. With `nil`, as inside a string, where whitespace counts,
  # and in a paste, keep the text as it is.
  defp break_line(editor, indent) do
    {before, after_} = split_line(editor)

    {before, after_, indent} =
      if indent,
        do: {String.trim_trailing(before), spaces(indent) <> String.trim_leading(after_), indent},
        else: {before, after_, 0}

    lines = List.replace_at(editor.lines, editor.row, before)
    lines = List.insert_at(lines, editor.row + 1, after_)
    %{editor | lines: lines, row: editor.row + 1, col: indent}
  end

  defp reindent(%{row: 0} = editor), do: set_indentation(editor, 0)

  defp reindent(editor) do
    before = editor.lines |> Enum.take(editor.row) |> Enum.join("\n")

    case Input.indentation(before) do
      nil -> editor
      indent -> set_indentation(editor, indent)
    end
  end

  defp set_indentation(editor, indent) do
    line = current_line(editor)
    trimmed = String.trim_leading(line)
    old = String.length(line) - String.length(trimmed)
    col = max(editor.col - old + indent, indent)
    %{put_line(editor, spaces(indent) <> trimmed) | col: col}
  end

  defp insert(editor, text) do
    {before, after_} = split_line(editor)
    # Count from the new line, since `text` can combine with the
    # grapheme before it, as a combining accent does.
    prefix = before <> text
    %{put_line(editor, prefix <> after_) | col: String.length(prefix)}
  end

  defp backspace(%{col: 0, row: 0} = editor), do: editor

  defp backspace(%{col: 0} = editor) do
    previous = Enum.at(editor.lines, editor.row - 1)
    joined = previous <> current_line(editor)
    lines = editor.lines |> List.delete_at(editor.row) |> List.replace_at(editor.row - 1, joined)
    %{editor | lines: lines, row: editor.row - 1, col: String.length(previous)}
  end

  defp backspace(editor) do
    {before, after_} = split_line(editor)
    %{put_line(editor, String.slice(before, 0..-2//1) <> after_) | col: editor.col - 1}
  end

  defp delete(editor) do
    {before, after_} = split_line(editor)

    cond do
      after_ != "" ->
        put_line(editor, before <> String.slice(after_, 1..-1//1))

      editor.row < length(editor.lines) - 1 ->
        next = Enum.at(editor.lines, editor.row + 1)
        lines = editor.lines |> List.delete_at(editor.row + 1)
        %{editor | lines: List.replace_at(lines, editor.row, before <> next)}

      true ->
        editor
    end
  end

  defp left(%{col: 0, row: 0} = editor), do: editor

  defp left(%{col: 0} = editor),
    do: %{editor | row: editor.row - 1} |> then(&%{&1 | col: line_length(&1)})

  defp left(editor), do: %{editor | col: editor.col - 1}

  defp right(editor) do
    cond do
      editor.col < line_length(editor) -> %{editor | col: editor.col + 1}
      editor.row < length(editor.lines) - 1 -> %{editor | row: editor.row + 1, col: 0}
      true -> editor
    end
  end

  defp word_left(editor) do
    {before, _after} = split_line(editor)
    kept = before |> String.graphemes() |> drop_word_back()
    %{editor | col: length(kept)}
  end

  defp word_right(editor) do
    {_before, after_} = split_line(editor)
    {spaces, rest} = after_ |> String.graphemes() |> Enum.split_while(&(not word?(&1)))
    word = Enum.take_while(rest, &word?/1)
    %{editor | col: editor.col + length(spaces) + length(word)}
  end

  defp drop_word_back(graphemes) do
    graphemes
    |> Enum.reverse()
    |> Enum.drop_while(&(not word?(&1)))
    |> Enum.drop_while(&word?/1)
    |> Enum.reverse()
  end

  defp word?(g), do: g not in [" ", "\t", "(", ")", "[", "]", "\"", "'", "`", ",", ";"]

  defp up(%{row: 0} = editor), do: history(editor, 1)
  defp up(editor), do: %{editor | row: editor.row - 1} |> clamp_col()

  defp down(%{row: row, lines: lines} = editor) when row == length(lines) - 1,
    do: history(editor, -1)

  defp down(editor), do: %{editor | row: editor.row + 1} |> clamp_col()

  defp clamp_col(editor), do: %{editor | col: min(editor.col, line_length(editor))}

  # Move `step` entries back (1) or forward (-1) through the history,
  # where `nil` is the entry being edited.
  defp history(editor, step) do
    index = (editor.history_index || -1) + step

    cond do
      index >= length(editor.history) ->
        editor

      index < 0 and editor.history_index == nil ->
        editor

      index < 0 ->
        show(%{editor | history_index: nil}, editor.draft)

      true ->
        draft = if editor.history_index == nil, do: text(editor), else: editor.draft
        show(%{editor | history_index: index, draft: draft}, Enum.at(editor.history, index))
    end
  end

  # Show `text` as the entry, with the cursor at its end.
  defp show(editor, text) do
    lines = String.split(text, "\n")
    row = length(lines) - 1
    %{editor | lines: lines, row: row, col: String.length(List.last(lines))}
  end

  # ---------------------------------------------------------------------------
  # Lines
  # ---------------------------------------------------------------------------

  defp current_line(editor), do: Enum.at(editor.lines, editor.row)
  defp line_length(editor), do: String.length(current_line(editor))

  defp put_line(editor, line),
    do: %{editor | lines: List.replace_at(editor.lines, editor.row, line)}

  defp split_line(editor), do: String.split_at(current_line(editor), editor.col)

  defp text_before_cursor(editor) do
    {before, after_} = split_line(editor)
    earlier = Enum.take(editor.lines, editor.row)
    {Enum.join(earlier ++ [before], "\n"), after_}
  end

  defp spaces(n), do: String.duplicate(" ", n)

  # ---------------------------------------------------------------------------
  # Drawing
  # ---------------------------------------------------------------------------

  defp move_to_end(editor) do
    row = length(editor.lines) - 1
    col = String.length(List.last(editor.lines))
    {_editor, output} = draw(editor, row, col)
    output
  end

  # Return to the entry's first screen row, clear to the end of the
  # screen, write the entry, and put the cursor at `{row, col}`.
  defp draw(editor, row, col) do
    lines =
      editor.lines
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        [if(i == 0, do: @prompt, else: @continuation), expand_tabs(line)]
      end)
      |> Enum.intersperse("\n")

    {end_row, end_col} = screen_position(editor, length(editor.lines) - 1, line_width(editor, -1))

    # A line that ends at the right margin leaves the cursor on the
    # last column until the next character is written. Move it to the
    # next row, where `screen_position/3` counts it.
    wrap = if end_col == 0, do: "\r\n", else: ""

    {target_row, target_col} = screen_position(editor, row, prefix_width(editor, row, col))

    output = [
      cursor_up(editor.screen_row),
      "\r\e[J",
      lines,
      wrap,
      cursor_up(end_row - target_row),
      "\r",
      cursor_right(target_col)
    ]

    {%{editor | screen_row: target_row}, output}
  end

  # The screen row and column, counted from the entry's first, of the
  # character `width` columns into line `row`, after its prompt. A line
  # that fills its last row exactly doesn't take another: the newline
  # after it moves to the next.
  defp screen_position(editor, row, width) do
    rows_before =
      editor.lines
      |> Enum.take(row)
      |> Enum.map(fn line ->
        div(String.length(@prompt) + display_width(line) - 1, editor.width) + 1
      end)
      |> Enum.sum()

    offset = String.length(@prompt) + width
    {rows_before + div(offset, editor.width), rem(offset, editor.width)}
  end

  defp line_width(editor, row), do: editor.lines |> Enum.at(row) |> display_width()

  defp prefix_width(editor, row, col),
    do: editor.lines |> Enum.at(row) |> String.slice(0, col) |> display_width()

  # The terminal cells `text` takes after the prompt: two for a wide
  # grapheme (East Asian wide and fullwidth characters, and most
  # emoji), one for any other, and for a tab, which only a paste
  # inserts, those up to the next tab stop.
  defp display_width(text) do
    prompt = String.length(@prompt)

    text
    |> String.graphemes()
    |> Enum.reduce(prompt, fn
      "\t", column -> next_tab_stop(column)
      grapheme, column -> column + cell_width(grapheme)
    end)
    |> Kernel.-(prompt)
  end

  # `line` with each tab replaced by the spaces up to the next tab
  # stop, as `display_width/1` counts it, so that the cursor is placed
  # the same whatever tab stops the terminal has.
  defp expand_tabs(line) do
    if String.contains?(line, "\t") do
      line
      |> String.split("\t")
      |> Enum.reduce(fn part, shown ->
        column = String.length(@prompt) + display_width(shown)
        shown <> String.duplicate(" ", next_tab_stop(column) - column) <> part
      end)
    else
      line
    end
  end

  defp next_tab_stop(column), do: (div(column, 8) + 1) * 8

  defp cell_width(<<c::utf8, _::binary>>) do
    if Enum.any?(@wide, &(c in &1)), do: 2, else: 1
  end

  defp cursor_up(0), do: []
  defp cursor_up(n), do: "\e[#{n}A"

  defp cursor_right(0), do: []
  defp cursor_right(n), do: "\e[#{n}C"
end

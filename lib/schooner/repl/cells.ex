defmodule Schooner.REPL.Cells do
  @moduledoc false

  # The terminal cells text takes in the REPL's editor, where each line
  # of an entry follows a prompt `margin/0` cells wide. The editor
  # places the cursor by these counts, and `Schooner.REPL.Input` lines
  # code up by them.
  #
  # A wide grapheme (East Asian wide and fullwidth characters, and most
  # emoji) takes two cells, and any other one. A tab, which only a paste
  # inserts, takes the cells up to the next tab stop, every eight cells
  # from the left of the screen. The editor shows it as those spaces, so
  # the count holds whatever tab stops the terminal has.

  @margin 10

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

  @doc "The width of the prompts, in cells."
  @spec margin() :: pos_integer()
  def margin, do: @margin

  @doc """
  The cells `text` takes when it starts `column` cells into a line,
  after the prompt.
  """
  @spec width(binary(), non_neg_integer()) :: non_neg_integer()
  def width(text, column \\ 0) do
    text
    |> String.graphemes()
    |> Enum.reduce(column, fn grapheme, column -> column + grapheme_width(grapheme, column) end)
    |> Kernel.-(column)
  end

  @doc """
  The cells `grapheme` takes when it starts `column` cells into a line,
  after the prompt.
  """
  @spec grapheme_width(binary(), non_neg_integer()) :: non_neg_integer()
  def grapheme_width("\t", column), do: 8 - rem(@margin + column, 8)

  def grapheme_width(<<c::utf8, _::binary>>, _column) do
    if Enum.any?(@wide, &(c in &1)), do: 2, else: 1
  end

  @doc """
  `line` with each tab replaced by the spaces `width/2` counts for it.
  """
  @spec expand_tabs(binary()) :: binary()
  def expand_tabs(line) do
    if String.contains?(line, "\t") do
      line
      |> String.split("\t")
      |> Enum.reduce(fn part, shown ->
        shown <> String.duplicate(" ", grapheme_width("\t", width(shown))) <> part
      end)
    else
      line
    end
  end
end

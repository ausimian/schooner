defmodule Schooner.REPL.EditorTest do
  use ExUnit.Case, async: true

  alias Schooner.REPL.Editor

  # Type `input` into `editor`, a key at a time, and return the actions
  # and the editor.
  defp type(editor \\ new(), input, width \\ 80) do
    {keys, ""} = Editor.feed("", input)

    Enum.reduce(keys, {[], editor}, fn key, {actions, editor} ->
      {action, editor, _output} = Editor.key(editor, key, width)
      {actions ++ [action], editor}
    end)
  end

  defp new do
    {editor, _prompt} = Editor.start(Editor.new())
    editor
  end

  # The text submitted by `input`.
  defp submitted(editor \\ new(), input) do
    {actions, _editor} = type(editor, input)
    for {:submit, text} <- actions, do: text
  end

  defp text(input) do
    {_actions, editor} = type(input)
    Editor.text(editor)
  end

  describe "feed/2" do
    test "splits characters and whole escape sequences" do
      assert Editor.feed("", "ab\e[A\e[3~é\eb\eOH") ==
               {["a", "b", "\e[A", "\e[3~", "é", "\eb", "\eOH"], ""}
    end

    test "keeps an unfinished escape sequence for the next call" do
      assert {["a"], "\e["} = Editor.feed("", "a\e[")
      assert {["\e[1;5C"], ""} = Editor.feed("\e[", "1;5C")
      assert {[], "\e"} = Editor.feed("", "\e")
      assert {["\e[200~", "x"], ""} = Editor.feed("\e", "[200~x")
    end
  end

  describe "Enter" do
    test "submits a complete entry" do
      assert submitted("(+ 1 2)\r") == ["(+ 1 2)"]
      assert submitted("1\n") == ["1"]
    end

    test "submits a blank entry, so the REPL can prompt again" do
      assert submitted("\r") == [""]
    end

    test "in an unfinished entry starts a new line, indented to where the code goes" do
      assert text("(define (f x)\r") == "(define (f x)\n  "
      assert text("(define (f x)\r(if x\r") == "(define (f x)\n  (if x\n      "
      assert text("(let ((a 1)\r") == "(let ((a 1)\n      "

      assert submitted("(define (f x)\r(let ((a 1)\r(b 2))\r(+ a b x)))\r") == [
               """
               (define (f x)
                 (let ((a 1)
                       (b 2))
                   (+ a b x)))\
               """
             ]
    end

    test "doesn't indent the line after one that ends inside a string" do
      assert text("(f \"ab\r") == "(f \"ab\n"
    end

    test "with the cursor inside a complete entry breaks the line there" do
      # Left from the end of `(f a b)` to before `b)`.
      assert text("(f a b)\e[D\e[D\r") == "(f a\n   b)"
    end

    test "submits a complete entry with only spaces after the cursor" do
      assert submitted("(f)  \e[D\r") == ["(f)  "]
    end
  end

  describe "Tab" do
    test "re-indents the line" do
      assert text("(define (f x)\r\x15(g x)\t") == "(define (f x)\n  (g x)"
      assert text("(define (f x)\r      (g x)\t") == "(define (f x)\n  (g x)"
    end

    test "keeps the cursor on the same character" do
      {_, editor} = type("(define (f x)\r      (g x)\e[D\e[D\t")
      assert editor.col == 5
    end

    test "on the first line removes its indentation" do
      assert text("   (f)\t") == "(f)"
    end

    test "inside a string leaves the line alone" do
      assert text("(f \"ab\r  cd\t") == "(f \"ab\n  cd"
    end
  end

  describe "editing" do
    test "inserts at the cursor" do
      assert text("(f b)\e[D\e[Da \e[F") == "(f a b)"
    end

    test "Backspace deletes before the cursor, and joins lines at the start of one" do
      assert text("abc\x7f") == "ab"
      assert text("(f\r\x15\x7fx") == "(fx"
    end

    test "Delete and Ctrl-D delete at the cursor, and join lines at the end of one" do
      assert text("abc\e[D\e[3~") == "ab"
      assert text("abc\x01\x04") == "bc"
      assert text("(f\r\x15x\e[A\e[F\e[3~") == "(fx"
    end

    test "Home, End, Ctrl-A and Ctrl-E move to the ends of the line" do
      assert text("bc\e[Ha\e[Fd") == "abcd"
      assert text("bc\x01a\x05d") == "abcd"
    end

    test "Ctrl-K and Ctrl-U delete to the ends of the line" do
      assert text("abcd\e[D\e[D\x0b") == "ab"
      assert text("abcd\e[D\e[D\x15") == "cd"
    end

    test "Ctrl-W deletes the word before the cursor" do
      assert text("(foo bar-baz\x17") == "(foo "
      assert text("(foo bar  \x17") == "(foo "
    end

    test "Alt-B and Alt-F move by words" do
      assert text("(foo bar)\ebX\efY") == "(foo XbarY)"
    end

    test "Left and Right cross lines" do
      {_, editor} = type("(f\r\x15x\e[D\e[D")
      assert {editor.row, editor.col} == {0, 2}
      {_, editor} = type(editor, "\e[C")
      assert {editor.row, editor.col} == {1, 0}
    end

    test "a combining character typed on its own joins the character before it" do
      {:continue, editor, _} = Editor.key(new(), "e", 80)
      {:continue, editor, _} = Editor.key(editor, "\u0301", 80)
      assert {Editor.text(editor), editor.col} == {"e\u0301", 1}

      {:continue, editor, _} = Editor.key(editor, "\x7f", 80)
      assert {Editor.text(editor), editor.col} == {"", 0}
    end

    test "control keys that do nothing are ignored" do
      assert text("a\x07\e[Zb") == "ab"
    end
  end

  describe "Ctrl-C and Ctrl-D" do
    test "Ctrl-C discards the entry" do
      {actions, editor} = type("(f x\r(g\x03")
      assert Enum.all?(actions, &(&1 == :continue))
      assert Editor.text(editor) == ""
    end

    test "Ctrl-D on an empty entry is the end of input" do
      assert {[:eof], _} = type("\x04")
    end
  end

  describe "history" do
    test "Up and Down move through earlier entries, then back to the draft" do
      {_, editor} = type("(a)\r")
      {editor, _} = Editor.start(editor)
      {_, editor} = type(editor, "(b\r1)\r")
      {editor, _} = Editor.start(editor)
      {_, editor} = type(editor, "dra")

      {_, editor} = type(editor, "\e[A")
      assert Editor.text(editor) == "(b\n 1)"
      # Up moves within a multi-line entry before going further back.
      {_, editor} = type(editor, "\e[A\e[A")
      assert Editor.text(editor) == "(a)"
      {_, editor} = type(editor, "\e[A")
      assert Editor.text(editor) == "(a)"

      {_, editor} = type(editor, "\e[B")
      assert Editor.text(editor) == "(b\n 1)"
      {_, editor} = type(editor, "\x0e\x0e")
      assert Editor.text(editor) == "dra"
    end

    test "leaves out blank entries and repeats" do
      {_, editor} = type("(a)\r")
      {editor, _} = Editor.start(editor)
      {_, editor} = type(editor, "(a)\r")
      {editor, _} = Editor.start(editor)
      {_, editor} = type(editor, "  \r")
      assert editor.history == ["(a)"]
    end
  end

  describe "bracketed paste" do
    test "inserts pasted newlines as they are, without indenting or submitting" do
      {actions, editor} = type("\e[200~(define (f x)\n    (g x))\n\e[201~")
      assert Enum.all?(actions, &(&1 == :continue))
      assert Editor.text(editor) == "(define (f x)\n    (g x))\n"
    end

    test "inserts a pasted tab, rather than re-indenting" do
      assert text("\e[200~(f \"a\tb\")\e[201~") == "(f \"a\tb\")"
    end

    test "takes a CRLF that arrives a character at a time as one newline" do
      {_, editor} = type("\e[200~(f\r")
      {_, editor} = type(editor, "\n 1)\r\r\n\e[201~")
      assert Editor.text(editor) == "(f\n 1)\n\n"
    end

    test "Enter after the paste submits it" do
      assert submitted("\e[200~(f\n 1)\e[201~\r") == ["(f\n 1)"]
    end
  end

  describe "drawing" do
    test "redraws the entry and puts the cursor back" do
      {:continue, editor, output} = Editor.key(new(), "(", 80)
      assert IO.iodata_to_binary(output) == "\r\e[Jschooner> (\r\e[11C"

      {:continue, _editor, output} = Editor.key(editor, "\r", 80)
      assert IO.iodata_to_binary(output) == "\r\e[Jschooner> (\n     ...>  \r\e[11C"
    end

    test "returns to the entry's first row before redrawing" do
      {_, editor} = type("(f\r")
      {:continue, _editor, output} = Editor.key(editor, "x", 80)
      assert IO.iodata_to_binary(output) == "\e[1A\r\e[Jschooner> (f\n     ...>  x\r\e[12C"
    end

    test "counts the rows a long line wraps onto" do
      # The prompt and `(f aaaaa` fill 18 of 10 columns: two rows.
      {_, editor} = type(new(), "(f aaaaa", 10)
      assert editor.screen_row == 1

      # The next line's prompt and indentation, 13 columns, take two
      # more, and the cursor is on the second.
      {_, editor} = type(editor, "\r", 10)
      assert editor.screen_row == 3
    end

    test "counts a wide character as two columns" do
      {:continue, _editor, output} = Editor.key(new(), "界", 80)
      assert IO.iodata_to_binary(output) == "\r\e[Jschooner> 界\r\e[12C"

      {_, editor} = type(new(), "界界", 12)
      assert editor.screen_row == 1
    end

    test "shows a pasted tab as spaces to the next tab stop, and counts them" do
      {_, editor} = type("\e[200~(f\ta)\e[201~")
      {:continue, _editor, output} = Editor.key(editor, "\e[D", 80)
      assert IO.iodata_to_binary(output) == "\r\e[Jschooner> (f    a)\r\e[17C"
    end

    test "moves to a new row when the line ends at the right margin" do
      {:continue, _editor, output} = Editor.key(new(), "x", 11)
      assert IO.iodata_to_binary(output) == "\r\e[Jschooner> x\r\n\r"
    end
  end
end

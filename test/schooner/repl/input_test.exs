defmodule Schooner.REPL.InputTest do
  use ExUnit.Case, async: true

  alias Schooner.REPL.Input

  describe "complete?/1" do
    test "source that reads is complete" do
      for text <- ["", "  ", "1", "(f x)", "(f x) (g y)", "; (comment", "#| ( |#", "\"(\"", "'a"] do
        assert Input.complete?(text), inspect(text)
      end
    end

    test "source that ends inside a datum isn't" do
      for text <- [
            "(f x",
            "(f (g x)",
            "(f x) (g",
            "#(1 2",
            "#u8(1",
            "\"abc",
            "(f \"a)\"",
            "#| comment",
            "|odd name",
            "#;",
            "'",
            "`(a ,",
            "(a .",
            "(f #\\( ",
            "(write-char #\\"
          ] do
        refute Input.complete?(text), inspect(text)
      end
    end

    test "source with a read error that more text can't fix is complete" do
      for text <- [")", "(a . )", "(a . b c)", "#u8(256)", "(1abc"] do
        assert Input.complete?(text), inspect(text)
      end
    end

    test "a meta-command is complete, unless the form after ,expand or ,time isn't" do
      assert Input.complete?(",env")
      assert Input.complete?(",load (unbalanced")
      assert Input.complete?(",time (f x)")
      refute Input.complete?(",time (f x")
      refute Input.complete?("  ,expand (when a\n")
    end
  end

  describe "command/1" do
    test "splits a meta-command into its name and arguments" do
      assert Input.command(",env str") == {"env", " str"}
      assert Input.command("  ,quit\n") == {"quit", "\n"}
      assert Input.command(",time (f\n x)") == {"time", " (f\n x)"}
    end

    test "a comma that doesn't start a name isn't one" do
      assert Input.command(",(f x)") == nil
      assert Input.command(",@x") == nil
      assert Input.command("(f ,x)") == nil
    end
  end

  describe "indentation/1" do
    # Each case is the text typed so far, with `|` where the next line
    # should start.
    @cases [
      # The body of a body form: two in.
      """
      (define (f x)
        ^
      """,
      """
      (lambda (x)
        ^
      """,
      """
      (let ((a 1))
        ^
      """,
      """
      (let loop ((i 0))
        ^
      """,
      """
      (when (> x 0)
        ^
      """,
      """
      ((lambda (x)
         ^
      """,
      # Distinguished arguments not yet typed: four in.
      """
      (define
          ^
      """,
      """
      (do ((i 0 (+ i 1)))
          ^
      """,
      """
      (let loop
          ^
      """,
      # A call: under the first argument, or under the head when there
      # isn't one yet.
      """
      (foo a
           ^
      """,
      """
      (if (> x 0)
          ^
      """,
      """
      (if (> x 0)
          (f x)
          ^
      """,
      """
      (foo
       ^
      """,
      """
      (cond ((a) 1)
            ^
      """,
      # A list that isn't a call: under the first item.
      """
      (let ((a 1)
            ^
      """,
      """
      '(a b
        ^
      """,
      """
      '(define x
        ^
      """,
      """
      #(1 2
        ^
      """,
      """
      (f '(1
           ^
      """,
      # Wide characters and pasted tabs count the cells they take.
      """
      (界 foo
          ^
      """,
      "(f\ta\n" <> String.duplicate(" ", 6) <> "^\n",
      # A datum a `#;` comments out isn't an item, even a list or
      # several stacked.
      """
      (foo #;ignored
       ^
      """,
      """
      (foo #;(a (b) c) #; #; x y
       ^
      """,
      """
      (foo #;(a
              ^
      """,
      """
      (foo #; #;(a b) c
       ^
      """,
      """
      (foo #; #;(a #;b c) d
       ^
      """,
      # Closed lists, strings, comments and characters don't count.
      """
      (define (f x)
        (g x))
      ^
      """,
      """
      (f "(" #\\( ; (
         ^
      """,
      """
      (f #| ( |#
       ^
      """,
      """
      (f |a (b|
         ^
      """
    ]

    test "lines code up the way Schooner.Pretty prints it" do
      for c <- @cases do
        {before, [marker]} =
          c |> String.trim_trailing("\n") |> String.split("\n") |> Enum.split(-1)

        text = Enum.join(before, "\n")
        expected = marker |> String.split("^") |> hd() |> String.length()

        assert Input.indentation(text) == expected, "after:\n#{text}"
      end
    end

    test "is nil inside a string, a |...| identifier or a block comment" do
      assert Input.indentation("(f \"abc") == nil
      assert Input.indentation("(f |abc") == nil
      assert Input.indentation("(f #| a") == nil
      assert Input.indentation("(f #| a #| b |# c") == nil
    end

    test "is 0 outside any list" do
      assert Input.indentation("") == 0
      assert Input.indentation("(f x)") == 0
      assert Input.indentation("(f x) ; (") == 0
    end
  end
end

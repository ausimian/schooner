defmodule Schooner.ReaderTest do
  use ExUnit.Case, async: true

  alias Schooner.Reader
  alias Schooner.Reader.Error
  alias Schooner.Value

  describe "atoms" do
    test "integer literal reads to a bare Elixir integer" do
      assert Reader.read_string("42") == [42]
      assert Reader.read_string("-7") == [-7]
      assert Reader.read_string("0") == [0]
    end

    test "float literal reads to a bare Elixir float" do
      assert Reader.read_string("1.5") == [1.5]
      assert Reader.read_string("-0.5") == [-0.5]
    end

    test "boolean literal reads to a bare boolean" do
      assert Reader.read_string("#t") == [Value.bool(true)]
      assert Reader.read_string("#false") == [Value.bool(false)]
    end

    test "string literal reads to a bare binary" do
      assert Reader.read_string(~S("hello")) == [Value.string("hello")]
    end

    test "char literal reads to {:char, _}" do
      assert Reader.read_string(~S(#\a)) == [Value.char(?a)]
      assert Reader.read_string(~S(#\space)) == [Value.char(?\s)]
    end

    test "identifier reads to a tagged symbol" do
      assert Reader.read_string("foo") == [Value.symbol("foo")]
      assert Reader.read_string("|hello world|") == [Value.symbol("hello world")]
      assert Reader.read_string("...") == [Value.symbol("...")]
    end

    test "empty input yields no datums" do
      assert Reader.read_string("") == []
      assert Reader.read_string("   \n\t  ") == []
      assert Reader.read_string("; just a comment\n") == []
    end
  end

  describe "lists" do
    test "empty list reads to :null" do
      assert Reader.read_string("()") == [[]]
    end

    test "proper list reads to nested pairs" do
      assert Reader.read_string("(1 2 3)") == [Value.list([1, 2, 3])]
    end

    test "list with mixed atoms" do
      datum = Reader.read_string("(define x 1)") |> hd()

      assert datum ==
               Value.list([Value.symbol("define"), Value.symbol("x"), 1])
    end

    test "dotted pair" do
      assert Reader.read_string("(1 . 2)") == [Value.pair(1, 2)]
    end

    test "improper list with multiple lead elements" do
      assert Reader.read_string("(1 2 . 3)") == [Value.improper_list([1, 2], 3)]
    end

    test "nested lists" do
      datum = Reader.read_string("(1 (2 3) 4)") |> hd()

      assert datum ==
               Value.list([1, Value.list([2, 3]), 4])
    end

    test "deeply nested" do
      datum = Reader.read_string("(((())))") |> hd()
      expected = Value.list([Value.list([Value.list([[]])])])
      assert datum == expected
    end
  end

  describe "vectors" do
    test "empty vector" do
      assert Reader.read_string("#()") == [Value.vector([])]
    end

    test "vector of integers" do
      assert Reader.read_string("#(1 2 3)") == [Value.vector([1, 2, 3])]
    end

    test "vector of mixed atoms" do
      datum = Reader.read_string(~S[#(1 "hi" foo)]) |> hd()

      assert datum ==
               Value.vector([1, Value.string("hi"), Value.symbol("foo")])
    end

    test "vectors may nest in lists" do
      datum = Reader.read_string("(a #(1 2) b)") |> hd()

      assert datum ==
               Value.list([
                 Value.symbol("a"),
                 Value.vector([1, 2]),
                 Value.symbol("b")
               ])
    end
  end

  describe "bytevectors" do
    test "empty bytevector" do
      assert Reader.read_string("#u8()") == [Value.bytevector([])]
    end

    test "bytevector of bytes" do
      assert Reader.read_string("#u8(1 2 255)") == [Value.bytevector([1, 2, 255])]
    end
  end

  describe "quote forms desugar" do
    test "'x → (quote x)" do
      assert Reader.read_string("'x") ==
               [Value.list([Value.symbol("quote"), Value.symbol("x")])]
    end

    test "`x → (quasiquote x)" do
      assert Reader.read_string("`x") ==
               [Value.list([Value.symbol("quasiquote"), Value.symbol("x")])]
    end

    test ",x → (unquote x)" do
      assert Reader.read_string(",x") ==
               [Value.list([Value.symbol("unquote"), Value.symbol("x")])]
    end

    test ",@x → (unquote-splicing x)" do
      assert Reader.read_string(",@x") ==
               [Value.list([Value.symbol("unquote-splicing"), Value.symbol("x")])]
    end

    test "stacked quotes" do
      datum = Reader.read_string("''x") |> hd()

      expected =
        Value.list([
          Value.symbol("quote"),
          Value.list([Value.symbol("quote"), Value.symbol("x")])
        ])

      assert datum == expected
    end

    test "quasiquote with unquote-splicing inside a list" do
      datum = Reader.read_string("`(a ,b ,@c)") |> hd()

      expected =
        Value.list([
          Value.symbol("quasiquote"),
          Value.list([
            Value.symbol("a"),
            Value.list([Value.symbol("unquote"), Value.symbol("b")]),
            Value.list([Value.symbol("unquote-splicing"), Value.symbol("c")])
          ])
        ])

      assert datum == expected
    end
  end

  describe "datum comments" do
    test "skip top-level datum" do
      assert Reader.read_string("#; foo bar") == [Value.symbol("bar")]
    end

    test "skip datum inside a list" do
      assert Reader.read_string("(a #; b c)") ==
               [Value.list([Value.symbol("a"), Value.symbol("c")])]
    end

    test "skip datum inside a vector" do
      assert Reader.read_string("#(1 #; 2 3)") == [Value.vector([1, 3])]
    end

    test "stacked datum comments skip multiple datums" do
      assert Reader.read_string("#; #; a b c") == [Value.symbol("c")]
    end

    test "datum comment at end of input is an error" do
      err = assert_raise Error, fn -> Reader.read_string("5 #;") end
      assert err.reason == :datum_comment_at_eof
    end
  end

  describe "multiple top-level datums" do
    test "two datums separated by whitespace" do
      assert Reader.read_string("1 2") == [1, 2]
    end

    test "definition followed by expression" do
      ds = Reader.read_string("(define x 1) (+ x 2)")

      assert ds == [
               Value.list([Value.symbol("define"), Value.symbol("x"), 1]),
               Value.list([Value.symbol("+"), Value.symbol("x"), 2])
             ]
    end
  end

  describe "nested data round-trips end-to-end" do
    test "vectors inside lists inside quasiquote inside lists" do
      src = "(begin `(a #(1 ,b) (c d)))"
      datum = Reader.read_string(src) |> hd()

      expected =
        Value.list([
          Value.symbol("begin"),
          Value.list([
            Value.symbol("quasiquote"),
            Value.list([
              Value.symbol("a"),
              Value.vector([1, Value.list([Value.symbol("unquote"), Value.symbol("b")])]),
              Value.list([Value.symbol("c"), Value.symbol("d")])
            ])
          ])
        ])

      assert datum == expected
    end
  end

  describe "errors carry source positions" do
    test "unmatched closing paren" do
      err = assert_raise Error, fn -> Reader.read_string("  )") end
      assert err.reason == :unexpected_close_paren
      assert err.position == {1, 3}
    end

    test "unterminated list points at the opening paren" do
      err = assert_raise Error, fn -> Reader.read_string("\n  (1 2 3") end
      assert err.reason == :unterminated_list
      assert err.position == {2, 3}
    end

    test "unterminated vector points at the opener" do
      err = assert_raise Error, fn -> Reader.read_string("#(1 2") end
      assert err.reason == :unterminated_vector
      assert err.position == {1, 1}
    end

    test "unterminated bytevector points at the opener" do
      err = assert_raise Error, fn -> Reader.read_string("#u8(1 2") end
      assert err.reason == :unterminated_bytevector
      assert err.position == {1, 1}
    end

    test "dot in wrong position — at list start" do
      err = assert_raise Error, fn -> Reader.read_string("(. 1)") end
      assert err.reason == :dot_at_list_start
      assert err.position == {1, 2}
    end

    test "dot at top level is unexpected" do
      err = assert_raise Error, fn -> Reader.read_string(" . ") end
      assert err.reason == :unexpected_dot
      assert err.position == {1, 2}
    end

    test "dot inside vector is rejected" do
      err = assert_raise Error, fn -> Reader.read_string("#(1 . 2)") end
      assert err.reason == :dot_in_vector
      assert err.position == {1, 5}
    end

    test "missing tail after dot" do
      err = assert_raise Error, fn -> Reader.read_string("(1 . )") end
      assert err.reason == :missing_tail_after_dot
      assert err.position == {1, 4}
    end

    test "more than one datum after dot" do
      err = assert_raise Error, fn -> Reader.read_string("(1 . 2 3)") end
      assert err.reason == :extra_after_dot
      assert err.position == {1, 8}
    end

    test "non-byte integer in bytevector" do
      err = assert_raise Error, fn -> Reader.read_string("#u8(1 256 3)") end
      assert err.reason == {:invalid_byte, 256}
      assert err.position == {1, 7}
    end

    test "non-integer token in bytevector" do
      err = assert_raise Error, fn -> Reader.read_string("#u8(1 foo 3)") end
      assert err.reason == {:invalid_in_bytevector, :ident}
      assert err.position == {1, 7}
    end

    test "quote with nothing following" do
      err = assert_raise Error, fn -> Reader.read_string("'") end
      assert err.reason == {:unexpected_eof_after, "quote"}
      assert err.position == {1, 1}
    end

    test "unquote-splicing with nothing following" do
      err = assert_raise Error, fn -> Reader.read_string(",@") end
      assert err.reason == {:unexpected_eof_after, "unquote-splicing"}
      assert err.position == {1, 1}
    end

    test "unterminated string surfaces the lexer error" do
      assert_raise Schooner.Lexer.Error, fn -> Reader.read_string(~s("abc)) end
    end

    test "unterminated block comment surfaces the lexer error" do
      assert_raise Schooner.Lexer.Error, fn -> Reader.read_string("#| oops") end
    end

    test "invalid #u8 byte at lex time surfaces the lexer error" do
      # `#u8(garbage)` reaches the reader as a bytevector_open then an
      # identifier, which is the reader's invalid_in_bytevector path.
      err = assert_raise Error, fn -> Reader.read_string("#u8(garbage)") end
      assert err.reason == {:invalid_in_bytevector, :ident}
    end
  end

  describe "read_string_positioned/1" do
    test "atom carries {:atom, position}" do
      assert [{42, {:atom, {1, 1}}}] = Reader.read_string_positioned("42")
      assert [{1.5, {:atom, {1, 4}}}] = Reader.read_string_positioned("   1.5")
    end

    test "every primitive token kind threads through position_of" do
      datums = Reader.read_string_positioned(~s|#t "hi" #\\a foo|)

      assert Enum.map(datums, fn {_d, p} -> Reader.position_of(p) end) ==
               [{1, 1}, {1, 4}, {1, 9}, {1, 13}]
    end

    test "list pos tree is a chain of :pair nodes pointing at the opener" do
      [{datum, pos_tree}] = Reader.read_string_positioned("  (a b c)")

      assert datum == Value.list([Value.symbol("a"), Value.symbol("b"), Value.symbol("c")])
      assert Reader.position_of(pos_tree) == {1, 3}

      [a_pos, b_pos, c_pos] = Reader.list_positions(pos_tree)
      assert Reader.position_of(a_pos) == {1, 4}
      assert Reader.position_of(b_pos) == {1, 6}
      assert Reader.position_of(c_pos) == {1, 8}
    end

    test "empty list reads as :null with an :atom-shaped position tree" do
      [{datum, pos_tree}] = Reader.read_string_positioned(" ()")
      assert datum == []
      assert pos_tree == {:atom, {1, 2}}
    end

    test "dotted-pair position tree records the tail's position in place of [] sentinel" do
      [{datum, pos_tree}] = Reader.read_string_positioned("(1 . 2)")
      assert datum == Value.pair(1, 2)

      assert {:pair, {1, 1}, {:atom, {1, 2}}, {:atom, {1, 6}}} = pos_tree
    end

    test "vector pos tree carries the start and an item-tree per element" do
      [{datum, pos_tree}] = Reader.read_string_positioned("#(1 2)")
      assert datum == Value.vector([1, 2])

      assert {:vector, {1, 1}, [item1, item2]} = pos_tree
      assert item1 == {:atom, {1, 3}}
      assert item2 == {:atom, {1, 5}}
    end

    test "bytevector pos tree carries only the start position" do
      [{datum, pos_tree}] = Reader.read_string_positioned("#u8(1 2)")
      assert datum == Value.bytevector([1, 2])
      assert pos_tree == {:bytevector, {1, 1}}
    end

    test "quote forms desugar with position trees pointing at the prefix" do
      [{datum, pos_tree}] = Reader.read_string_positioned(" 'foo")

      assert datum == Value.list([Value.symbol("quote"), Value.symbol("foo")])

      [quote_sym_pos, foo_pos] = Reader.list_positions(pos_tree)
      assert Reader.position_of(quote_sym_pos) == {1, 2}
      assert Reader.position_of(foo_pos) == {1, 3}
    end

    test "quasiquote, unquote, unquote-splicing all tracked" do
      [{_, p1}] = Reader.read_string_positioned("`x")
      [{_, p2}] = Reader.read_string_positioned(",x")
      [{_, p3}] = Reader.read_string_positioned(",@x")

      assert Reader.position_of(p1) == {1, 1}
      assert Reader.position_of(p2) == {1, 1}
      assert Reader.position_of(p3) == {1, 1}
    end

    test "datum comments are skipped while preserving positions of survivors" do
      [{datum, pos_tree}] = Reader.read_string_positioned("#; foo bar")
      assert datum == Value.symbol("bar")
      assert Reader.position_of(pos_tree) == {1, 8}
    end

    test "improper list — vector item carries its sub-tree" do
      [{datum, pos_tree}] = Reader.read_string_positioned("(#(1 2) . 3)")
      assert datum == Value.pair(Value.vector([1, 2]), 3)

      assert {:pair, _, vec_pos, tail_pos} = pos_tree
      assert {:vector, _, [_, _]} = vec_pos
      assert tail_pos == {:atom, {1, 11}}
    end

    test "errors during positioned read still raise with reader.error" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("(") end
      assert err.reason == :unterminated_list
      assert err.position == {1, 1}
    end

    test "positioned reader rejects unmatched close-paren" do
      err = assert_raise Error, fn -> Reader.read_string_positioned(" )") end
      assert err.reason == :unexpected_close_paren
      assert err.position == {1, 2}
    end

    test "positioned reader rejects bare dot" do
      err = assert_raise Error, fn -> Reader.read_string_positioned(" . ") end
      assert err.reason == :unexpected_dot
    end

    test "positioned reader rejects dot at list start" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("(. 1)") end
      assert err.reason == :dot_at_list_start
    end

    test "positioned reader rejects extra after dot" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("(1 . 2 3)") end
      assert err.reason == :extra_after_dot
    end

    test "positioned reader rejects missing tail after dot" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("(1 . )") end
      assert err.reason == :missing_tail_after_dot

      err = assert_raise Error, fn -> Reader.read_string_positioned("(1 . ") end
      assert err.reason == :missing_tail_after_dot
    end

    test "positioned reader rejects unterminated dotted-list (eof after tail)" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("(1 . 2") end
      assert err.reason == :unterminated_list
    end

    test "positioned reader rejects unterminated vector" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("#(1 2") end
      assert err.reason == :unterminated_vector
    end

    test "positioned reader rejects dot in vector" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("#(1 . 2)") end
      assert err.reason == :dot_in_vector
    end

    test "positioned reader rejects quote with no following datum" do
      err = assert_raise Error, fn -> Reader.read_string_positioned("'") end
      assert err.reason == {:unexpected_eof_after, "quote"}
    end
  end

  describe "list_positions/1" do
    test "raises ArgumentError for a non-list-shaped tree (vector)" do
      [{_, pos_tree}] = Reader.read_string_positioned("#(1 2)")

      assert_raise ArgumentError, fn -> Reader.list_positions(pos_tree) end
    end
  end
end

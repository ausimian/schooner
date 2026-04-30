defmodule Schooner.LexerTest do
  use ExUnit.Case, async: true

  alias Schooner.Lexer
  alias Schooner.Lexer.Error

  describe "punctuation and quote forms" do
    test "parens and quote markers" do
      assert Lexer.tokenise("()") == [
               {:lparen, nil, {1, 1}},
               {:rparen, nil, {1, 2}}
             ]

      assert Lexer.tokenise("'`,@,") == [
               {:quote, nil, {1, 1}},
               {:quasiquote, nil, {1, 2}},
               {:unquote_splicing, nil, {1, 3}},
               {:unquote, nil, {1, 5}}
             ]
    end

    test "vector and bytevector openers" do
      assert Lexer.tokenise("#( ") == [{:vector_open, nil, {1, 1}}]
      assert Lexer.tokenise("#u8(") == [{:bytevector_open, nil, {1, 1}}]
    end

    test "dot is its own token only with surrounding whitespace" do
      assert [
               {:lparen, _, _},
               {:ident, "a", _},
               {:dot, nil, _},
               {:ident, "b", _},
               {:rparen, _, _}
             ] = Lexer.tokenise("(a . b)")
    end

    test "ellipsis identifier is distinct from dot" do
      assert [{:ident, "...", {1, 1}}] = Lexer.tokenise("...")
    end
  end

  describe "booleans" do
    test "short and long forms" do
      assert [{:bool, true, {1, 1}}] = Lexer.tokenise("#t")
      assert [{:bool, false, {1, 1}}] = Lexer.tokenise("#f")
      assert [{:bool, true, {1, 1}}] = Lexer.tokenise("#true")
      assert [{:bool, false, {1, 1}}] = Lexer.tokenise("#false")
    end

    test "must be terminated by whitespace, paren, or other token boundary" do
      assert_raise Error, fn -> Lexer.tokenise("#tx") end
      assert_raise Error, fn -> Lexer.tokenise("#trues") end
    end
  end

  describe "characters" do
    test "single ascii char" do
      assert [{:char, ?a, {1, 1}}] = Lexer.tokenise(~S(#\a))
      assert [{:char, ?A, {1, 1}}] = Lexer.tokenise(~S(#\A))
      assert [{:char, ?0, {1, 1}}] = Lexer.tokenise(~S(#\0))
      assert [{:char, ?(, {1, 1}}] = Lexer.tokenise(~S(#\())
    end

    test "named characters" do
      assert [{:char, ?\s, _}] = Lexer.tokenise(~S(#\space))
      assert [{:char, ?\n, _}] = Lexer.tokenise(~S(#\newline))
      assert [{:char, ?\t, _}] = Lexer.tokenise(~S(#\tab))
      assert [{:char, 0, _}] = Lexer.tokenise(~S(#\null))
      assert [{:char, 0x1B, _}] = Lexer.tokenise(~S(#\escape))
    end

    test "hex characters" do
      assert [{:char, 0x41, _}] = Lexer.tokenise(~S(#\x41))
      assert [{:char, 0x10FFFF, _}] = Lexer.tokenise(~S(#\x10FFFF))
    end

    test "unknown char name raises" do
      assert_raise Error, fn -> Lexer.tokenise(~S(#\notachar)) end
    end

    test "trailing #\\ with no character is an unterminated literal" do
      err = assert_raise Error, fn -> Lexer.tokenise("#\\") end
      assert err.reason == :unterminated_char_literal
    end

    test "#\\xZZ is a named-char lookup, not a hex escape" do
      err = assert_raise Error, fn -> Lexer.tokenise(~S(#\xZZ)) end
      assert match?({:unknown_char_name, "xZZ"}, err.reason)
    end
  end

  describe "strings" do
    test "simple literal" do
      assert [{:string, "hello", {1, 1}}] = Lexer.tokenise(~s("hello"))
    end

    test "common escape sequences" do
      assert [{:string, "a\nb", _}] = Lexer.tokenise(~S("a\nb"))
      assert [{:string, "a\tb", _}] = Lexer.tokenise(~S("a\tb"))
      assert [{:string, "a\rb", _}] = Lexer.tokenise(~S("a\rb"))
      assert [{:string, ~s(a"b), _}] = Lexer.tokenise(~S("a\"b"))
      assert [{:string, "a\\b", _}] = Lexer.tokenise(~S("a\\b"))
    end

    test "hex escape" do
      assert [{:string, "A", _}] = Lexer.tokenise(~S("\x41;"))
      # multi-byte codepoint
      assert [{:string, "λ", _}] = Lexer.tokenise(~S("\x3BB;"))
    end

    test "raw newline inside string is preserved as \\n" do
      assert [{:string, "a\nb", _}] = Lexer.tokenise("\"a\nb\"")
    end

    test "unterminated string raises with start position" do
      err =
        assert_raise Error, fn -> Lexer.tokenise(~s("abc)) end

      assert err.reason == :unterminated_string
      assert err.position == {1, 1}
    end

    test "invalid escape raises" do
      err =
        assert_raise Error, fn -> Lexer.tokenise(~S("a\q")) end

      assert match?({:invalid_escape, ?q}, err.reason)
    end

    test "empty hex escape raises" do
      err =
        assert_raise Error, fn -> Lexer.tokenise(~S("\x;")) end

      assert err.reason == :empty_hex_escape
    end

    test "alarm and bar escapes" do
      assert [{:string, <<7>>, _}] = Lexer.tokenise(~S("\a"))
      assert [{:string, "|", _}] = Lexer.tokenise(~S("\|"))
    end

    test "raw CR and CRLF inside string become \\n" do
      assert [{:string, "a\nb", _}] = Lexer.tokenise("\"a\rb\"")
      assert [{:string, "a\nb", _}] = Lexer.tokenise("\"a\r\nb\"")
    end

    test "unterminated hex escape (no terminator) raises" do
      err = assert_raise Error, fn -> Lexer.tokenise(~S("\x41")) end
      assert err.reason in [:unterminated_hex_escape, :unterminated_string]
    end
  end

  describe "identifiers" do
    test "simple identifier" do
      assert [{:ident, "foo", {1, 1}}] = Lexer.tokenise("foo")
      assert [{:ident, "foo-bar", _}] = Lexer.tokenise("foo-bar")
      assert [{:ident, "list->vector", _}] = Lexer.tokenise("list->vector")
      assert [{:ident, "set!", _}] = Lexer.tokenise("set!")
      assert [{:ident, "x?", _}] = Lexer.tokenise("x?")
      assert [{:ident, "<=", _}] = Lexer.tokenise("<=")
    end

    test "peculiar identifiers" do
      assert [{:ident, "+", _}] = Lexer.tokenise("+")
      assert [{:ident, "-", _}] = Lexer.tokenise("-")
      assert [{:ident, "...", _}] = Lexer.tokenise("...")
      assert [{:ident, "->", _}] = Lexer.tokenise("->")
      assert [{:ident, "->foo", _}] = Lexer.tokenise("->foo")
    end

    test "vertical-bar quoted identifier" do
      assert [{:ident, "hello world", {1, 1}}] = Lexer.tokenise("|hello world|")
      assert [{:ident, "a|b", _}] = Lexer.tokenise(~S(|a\|b|))
      assert [{:ident, "a\\b", _}] = Lexer.tokenise(~S(|a\\b|))
      assert [{:ident, "", _}] = Lexer.tokenise("||")
    end

    test "unterminated bar identifier raises" do
      err =
        assert_raise Error, fn -> Lexer.tokenise("|hello") end

      assert err.reason == :unterminated_bar_identifier
    end

    test "bar identifier supports \\n \\t \\xHH; \\\\ escapes and embedded newlines" do
      assert [{:ident, "a\nb", _}] = Lexer.tokenise(~S(|a\nb|))
      assert [{:ident, "a\tb", _}] = Lexer.tokenise(~S(|a\tb|))
      assert [{:ident, "A", _}] = Lexer.tokenise(~S(|\x41;|))
      assert [{:ident, "a\nb", _}] = Lexer.tokenise("|a\nb|")
      assert [{:ident, "a\nb", _}] = Lexer.tokenise("|a\r\nb|")
    end

    test "unicode identifiers" do
      assert [{:ident, "λ", _}] = Lexer.tokenise("λ")
      assert [{:ident, "α-β", _}] = Lexer.tokenise("α-β")
    end
  end

  describe "numbers" do
    test "exact integers" do
      assert [{:integer, 0, _}] = Lexer.tokenise("0")
      assert [{:integer, 42, _}] = Lexer.tokenise("42")
      assert [{:integer, -7, _}] = Lexer.tokenise("-7")
      assert [{:integer, 7, _}] = Lexer.tokenise("+7")
    end

    test "inexact reals" do
      assert [{:float, 1.5, _}] = Lexer.tokenise("1.5")
      assert [{:float, -1.5, _}] = Lexer.tokenise("-1.5")
      assert [{:float, 0.5, _}] = Lexer.tokenise(".5")
      assert [{:float, -0.5, _}] = Lexer.tokenise("-.5")
      assert [{:float, 1.0, _}] = Lexer.tokenise("1.")
      assert [{:float, 150.0, _}] = Lexer.tokenise("1.5e2")
      assert [{:float, 100.0, _}] = Lexer.tokenise("1e2")
    end

    test "radix prefixes" do
      assert [{:integer, 5, _}] = Lexer.tokenise("#b101")
      assert [{:integer, 15, _}] = Lexer.tokenise("#o17")
      assert [{:integer, 255, _}] = Lexer.tokenise("#xff")
      assert [{:integer, 12, _}] = Lexer.tokenise("#d12")
      assert [{:integer, -5, _}] = Lexer.tokenise("#b-101")
      assert [{:integer, 31, _}] = Lexer.tokenise("#x1F")
    end

    test "hex literal containing E digit is integer, not float" do
      # `e` / `E` are valid hex digits, not the base-10 exponent marker.
      assert [{:integer, 0xCE, _}] = Lexer.tokenise("#xCE")
      assert [{:integer, 0xCE, _}] = Lexer.tokenise("#xce")
      assert [{:integer, 0xDEAD, _}] = Lexer.tokenise("#xDEAD")
    end

    test "exactness prefixes" do
      assert [{:integer, 1, _}] = Lexer.tokenise("#e1.5") |> Enum.map(&clamp/1)
      # #e on a float truncates / converts to integer
      assert [{:integer, 1, _}] = Lexer.tokenise("#e1.5")
      # #i on an integer makes it inexact
      assert [{:float, 3.0, _}] = Lexer.tokenise("#i3")
    end

    test "stacked radix + exactness prefixes" do
      assert [{:float, 255.0, _}] = Lexer.tokenise("#i#xff")
      assert [{:float, 255.0, _}] = Lexer.tokenise("#x#iff")
    end

    test "duplicate prefix is an error" do
      err = assert_raise Error, fn -> Lexer.tokenise("#x#x10") end
      assert match?({:duplicate_number_prefix, _}, err.reason)
    end

    test "rationals tokenise to {:rational, _, _}" do
      assert [{:rational, {:rational, 1, 2}, _}] = Lexer.tokenise("1/2")
      assert [{:rational, {:rational, -3, 4}, _}] = Lexer.tokenise("-3/4")
      assert [{:rational, {:rational, 1, 2}, _}] = Lexer.tokenise("3/6")
    end

    test "rational with denominator 1 collapses to integer token" do
      assert [{:integer, 5, _}] = Lexer.tokenise("5/1")
      assert [{:integer, -5, _}] = Lexer.tokenise("-10/2")
    end

    test "#i on a rational widens to float" do
      assert [{:float, 0.5, _}] = Lexer.tokenise("#i1/2")
    end

    test "#e on a rational stays exact" do
      assert [{:rational, {:rational, 1, 2}, _}] = Lexer.tokenise("#e1/2")
    end

    test "rational under non-decimal radix" do
      assert [{:rational, {:rational, 1, 10}, _}] = Lexer.tokenise("#x1/a")
      assert [{:rational, {:rational, 5, 6}, _}] = Lexer.tokenise("#b101/110")
    end

    test "rational with zero denominator is invalid" do
      err = assert_raise Error, fn -> Lexer.tokenise("1/0") end
      assert match?({:invalid_numeric_literal, _}, err.reason)
    end

    test "malformed rational shapes are invalid numeric literals" do
      assert_raise Error, fn -> Lexer.tokenise("1/") end
      assert_raise Error, fn -> Lexer.tokenise("1/2/3") end
      assert_raise Error, fn -> Lexer.tokenise("1.5/2") end
      assert_raise Error, fn -> Lexer.tokenise("1/-2") end
    end

    test "non-decimal radix forbids fractional point" do
      assert_raise Error, fn -> Lexer.tokenise("#x1.5") end
    end

    test "empty body after #-prefix is invalid_numeric_literal" do
      err = assert_raise Error, fn -> Lexer.tokenise("#x") end
      assert err.reason == :invalid_numeric_literal
    end

    test "non-finite float specials are recognised as float tokens" do
      assert [{:float, {:float_special, :pos_inf}, _}] = Lexer.tokenise("+inf.0")
      assert [{:float, {:float_special, :neg_inf}, _}] = Lexer.tokenise("-inf.0")
      assert [{:float, {:float_special, :nan}, _}] = Lexer.tokenise("+nan.0")
      assert [{:float, {:float_special, :nan}, _}] = Lexer.tokenise("-nan.0")
    end

    test "arbitrary-precision integers" do
      big = String.duplicate("9", 80)
      assert [{:integer, n, _}] = Lexer.tokenise(big)
      assert n == String.to_integer(big)
    end

    test "garbage after digits is an error" do
      err = assert_raise Error, fn -> Lexer.tokenise("10abc") end
      assert match?({:invalid_numeric_literal, "10abc"}, err.reason)
    end

    test "rectangular complex literals" do
      assert [{:complex, {:complex, 3, 4}, _}] = Lexer.tokenise("3+4i")
      assert [{:complex, {:complex, 3, -4}, _}] = Lexer.tokenise("3-4i")
      assert [{:complex, {:complex, -2.5, -1.0}, _}] = Lexer.tokenise("-2.5-1.0i")
    end

    test "unit-imaginary literals" do
      assert [{:complex, {:complex, 0, 1}, _}] = Lexer.tokenise("+i")
      assert [{:complex, {:complex, 0, -1}, _}] = Lexer.tokenise("-i")
      assert [{:complex, {:complex, 5, 1}, _}] = Lexer.tokenise("5+i")
      assert [{:complex, {:complex, 5, -1}, _}] = Lexer.tokenise("5-i")
    end

    test "complex with rational components" do
      assert [{:complex, {:complex, {:rational, 1, 2}, {:rational, 3, 4}}, _}] =
               Lexer.tokenise("1/2+3/4i")
    end

    test "exponent in real part not mistaken for imag-sign splitter" do
      assert [{:complex, {:complex, 1.0e-3, 2}, _}] = Lexer.tokenise("1.0e-3+2i")
    end

    test "polar literal converts to rectangular floats" do
      [{:complex, {:complex, r, i}, _}] = Lexer.tokenise("1@0")
      assert_in_delta r, 1.0, 1.0e-12
      assert_in_delta i, 0.0, 1.0e-12
    end

    defp clamp({:integer, n, _}) when n in -1..1, do: {:integer, n, nil}
    defp clamp(t), do: t
  end

  describe "comments" do
    test "line comment terminates at newline" do
      tokens = Lexer.tokenise("; ignored\n42")
      assert [{:integer, 42, {2, 1}}] = tokens
    end

    test "line comment to EOF" do
      assert [] = Lexer.tokenise("; just a comment")
    end

    test "block comment, including nested" do
      assert [{:integer, 1, _}] = Lexer.tokenise("#| outer #| inner |# outer |# 1")
    end

    test "block comment can span lines" do
      assert [{:integer, 1, {3, 3}}] = Lexer.tokenise("#| a\nb\n|#1")
    end

    test "line comment ends at lone CR or CRLF as well as LF" do
      assert [{:integer, 1, {2, 1}}] = Lexer.tokenise("; oops\r\n1")
      assert [{:integer, 1, {2, 1}}] = Lexer.tokenise("; oops\r1")
    end

    test "block comment handles CR/CRLF/LF newlines without losing track of depth" do
      assert [{:integer, 1, _}] = Lexer.tokenise("#|\r\n a \n b \r |# 1")
    end

    test "unterminated block comment raises with opening position" do
      err = assert_raise Error, fn -> Lexer.tokenise("#| oops") end
      assert err.reason == :unterminated_block_comment
      assert err.position == {1, 1}
    end

    test "datum-comment marker is preserved" do
      assert [
               {:datum_comment, nil, {1, 1}},
               {:integer, 7, _}
             ] = Lexer.tokenise("#; 7")
    end
  end

  describe "source positions" do
    test "tracks line and column across multi-line input" do
      src = """
      (define x 1)
      (define y 2)
      """

      tokens = Lexer.tokenise(src)

      assert [
               {:lparen, nil, {1, 1}},
               {:ident, "define", {1, 2}},
               {:ident, "x", {1, 9}},
               {:integer, 1, {1, 11}},
               {:rparen, nil, {1, 12}},
               {:lparen, nil, {2, 1}},
               {:ident, "define", {2, 2}},
               {:ident, "y", {2, 9}},
               {:integer, 2, {2, 11}},
               {:rparen, nil, {2, 12}}
             ] = tokens
    end

    test "tabs count as one column for now" do
      assert [{:ident, "x", {1, 2}}] = Lexer.tokenise("\tx")
    end

    test "CRLF and lone CR are both newlines" do
      assert [{:integer, 1, {2, 1}}] = Lexer.tokenise("\r\n1")
      assert [{:integer, 1, {2, 1}}] = Lexer.tokenise("\r1")
    end
  end

  describe "negative cases" do
    test "stray closing bracket-style char is an unexpected character" do
      err = assert_raise Error, fn -> Lexer.tokenise("@") end
      assert match?({:unexpected_char, ?@}, err.reason)
    end

    test "lone hash is an error" do
      assert_raise Error, fn -> Lexer.tokenise("#") end
    end

    test "unknown #-form raises invalid_hash_form" do
      err = assert_raise Error, fn -> Lexer.tokenise("#?") end
      assert match?({:invalid_hash_form, ?\?}, err.reason)
    end

    test "leading dot followed by garbage is an invalid token" do
      err = assert_raise Error, fn -> Lexer.tokenise(".+@") end
      assert match?({:invalid_token, _}, err.reason)
    end

    test "Lexer.Error message describes :empty_atom" do
      err = Error.exception(reason: :empty_atom, position: {1, 1})
      assert err.message == "empty token at line 1, column 1"
    end

    test "Lexer.Error message describes {:invalid_identifier, raw}" do
      err =
        Error.exception(reason: {:invalid_identifier, "x@y"}, position: {1, 1})

      assert err.message =~ "invalid identifier"
      assert err.message =~ "x@y"
    end
  end
end

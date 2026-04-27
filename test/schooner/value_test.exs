defmodule Schooner.ValueTest do
  use ExUnit.Case, async: true

  alias Schooner.Value

  describe "constructors and predicates" do
    test "booleans" do
      assert Value.bool(true) == true
      assert Value.bool(false) == false
      assert Value.boolean?(true)
      assert Value.boolean?(false)
      refute Value.boolean?(:null)
      refute Value.boolean?(0)
      refute Value.boolean?({:sym, "true"})
    end

    test "null" do
      assert Value.null?(:null)
      refute Value.null?(false)
      refute Value.null?({:pair, :null, :null})
    end

    test "pairs" do
      assert Value.pair(1, 2) == {:pair, 1, 2}
      assert Value.pair?({:pair, :null, :null})
      refute Value.pair?(:null)
    end

    test "list? recognises proper lists only" do
      assert Value.list?(:null)
      assert Value.list?(Value.list([1, 2, 3]))
      refute Value.list?(Value.improper_list([1, 2], 3))
      refute Value.list?(42)
      refute Value.list?({:string, "abc"})
    end

    test "list builders" do
      assert Value.list([]) == :null
      assert Value.list([1, 2, 3]) == {:pair, 1, {:pair, 2, {:pair, 3, :null}}}

      assert Value.improper_list([1, 2], 3) ==
               {:pair, 1, {:pair, 2, 3}}

      assert Value.improper_list([1], 2) == {:pair, 1, 2}
    end

    test "symbols are tagged binaries, never atoms" do
      sym = Value.symbol("foo")
      assert sym == {:sym, "foo"}
      assert Value.symbol?(sym)
      refute Value.symbol?(:foo)
      refute Value.symbol?("foo")
    end

    test "strings, chars, numbers" do
      assert Value.string?(Value.string("hi"))
      assert Value.char?(Value.char(?a))
      assert Value.number?(0)
      assert Value.number?(1.5)
      refute Value.number?(false)
      assert Value.integer?(1)
      assert Value.integer?(1.0)
      refute Value.integer?(1.5)
      assert Value.exact?(1)
      refute Value.exact?(1.0)
      assert Value.inexact?(1.0)
      refute Value.inexact?(1)
    end

    test "vectors and bytevectors" do
      v = Value.vector([1, 2, 3])
      assert Value.vector?(v)
      assert v == {:vector, {1, 2, 3}}

      bv = Value.bytevector([1, 2, 3])
      assert Value.bytevector?(bv)
      assert bv == {:bytevector, <<1, 2, 3>>}

      assert Value.bytevector(<<4, 5, 6>>) == {:bytevector, <<4, 5, 6>>}
    end

    test "procedures" do
      c = Value.closure([], [], %{}, "id")
      p = Value.primitive("noop", 0, fn _ -> :unspecified end)
      assert Value.procedure?(c)
      assert Value.procedure?(p)
      refute Value.procedure?({:sym, "id"})
    end

    test "records, eof, unspecified" do
      r = Value.record({:type, "point"}, {1, 2})
      assert Value.record?(r)
      refute Value.record?({:vector, {1, 2}})
      assert Value.eof?(:eof)
      assert Value.unspecified?(:unspecified)
      refute Value.unspecified?(:null)
      refute Value.unspecified?(false)
    end

    test "error_object? / error_kind?" do
      err = {:error_obj, :user, {:string, "boom"}, []}
      assert Value.error_object?(err)
      refute Value.error_object?({:string, "boom"})
      assert Value.error_kind?(err, :user)
      refute Value.error_kind?(err, :read)
      refute Value.error_kind?({:string, "x"}, :user)
    end

    test "integer? on non-finite floats is false (ArgumentError fallback)" do
      # `trunc/1` raises ArgumentError on non-finite floats; the
      # `integer?` rescue clause turns that into `false`.
      refute Value.integer?({:float_special, :nan})
      refute Value.integer?({:float_special, :pos_inf})
    end

    test "truthiness — only #f is false" do
      refute Value.truthy?(false)
      assert Value.truthy?(true)
      assert Value.truthy?(:null)
      assert Value.truthy?(0)
      assert Value.truthy?(0.0)
      assert Value.truthy?(Value.string(""))
    end
  end

  describe "eq? / eqv? / equal?" do
    test "numbers compare with exactness preserved" do
      assert Value.eqv?(1, 1)
      assert Value.eqv?(1.0, 1.0)
      refute Value.eqv?(1, 1.0)
      refute Value.eqv?(0, 0.0)
    end

    test "symbols, booleans, null, eof compare structurally" do
      assert Value.eq?(Value.symbol("a"), Value.symbol("a"))
      refute Value.eq?(Value.symbol("a"), Value.symbol("b"))
      assert Value.eq?(true, true)
      assert Value.eq?(:null, :null)
      assert Value.eq?(:eof, :eof)
    end

    test "characters compare by codepoint" do
      assert Value.eqv?(Value.char(?a), Value.char(?a))
      refute Value.eqv?(Value.char(?a), Value.char(?A))
    end

    test "equal? recurses into pairs" do
      l1 = Value.list([1, 2, 3])
      l2 = Value.list([1, 2, 3])
      l3 = Value.list([1, 2, 4])
      assert Value.equal?(l1, l2)
      refute Value.equal?(l1, l3)
    end

    test "equal? recurses into vectors" do
      v1 = Value.vector([Value.symbol("a"), 1, Value.string("hi")])
      v2 = Value.vector([Value.symbol("a"), 1, Value.string("hi")])
      v3 = Value.vector([Value.symbol("a"), 1, Value.string("HI")])
      assert Value.equal?(v1, v2)
      refute Value.equal?(v1, v3)
    end

    test "equal? on strings is byte-equal" do
      assert Value.equal?(Value.string("hi"), Value.string("hi"))
      refute Value.equal?(Value.string("hi"), Value.string("HI"))
    end

    test "equal? on bytevectors is byte-equal" do
      assert Value.equal?(Value.bytevector([1, 2, 3]), Value.bytevector(<<1, 2, 3>>))
      refute Value.equal?(Value.bytevector([1, 2, 3]), Value.bytevector([1, 2, 4]))
    end

    test "equal? on records requires same type id and equal fields" do
      a = Value.record({:type, "p"}, {1, 2})
      b = Value.record({:type, "p"}, {1, 2})
      c = Value.record({:type, "q"}, {1, 2})
      d = Value.record({:type, "p"}, {1, 3})
      assert Value.equal?(a, b)
      refute Value.equal?(a, c)
      refute Value.equal?(a, d)
    end

    test "equal? falls through to eqv? for non-aggregates" do
      refute Value.equal?(1, 1.0)
      assert Value.equal?(Value.symbol("x"), Value.symbol("x"))
    end

    test "equal? — NaN on the right side is also never equal" do
      refute Value.equal?(1, {:float_special, :nan})
      refute Value.equal?({:float_special, :pos_inf}, {:float_special, :nan})
    end

    test "equal? on differently-sized vectors and records is false" do
      refute Value.equal?(Value.vector([1, 2]), Value.vector([1, 2, 3]))
      a = Value.record({:type, "p"}, {1, 2})
      b = Value.record({:type, "p"}, {1, 2, 3})
      refute Value.equal?(a, b)
    end
  end

  describe "write / display" do
    test "atoms" do
      assert Value.write(true) == "#t"
      assert Value.write(false) == "#f"
      assert Value.write(:null) == "()"
      assert Value.write(:eof) == "#<eof>"
      assert Value.write(:unspecified) == "#<unspecified>"
    end

    test "numbers" do
      assert Value.write(0) == "0"
      assert Value.write(-42) == "-42"
      assert Value.write(1.0) == "1.0"
      assert Value.write(1.5) == "1.5"
      assert Value.write(0.1) == "0.1"
    end

    test "symbols" do
      assert Value.write(Value.symbol("foo")) == "foo"
      assert Value.write(Value.symbol("hello world")) == "|hello world|"
      assert Value.write(Value.symbol("a|b")) == "|a\\|b|"
      assert Value.write(Value.symbol("")) == "||"
      assert Value.write(Value.symbol("123abc")) == "|123abc|"
    end

    test "symbols — backslash and DEL force bar quoting and escape inside" do
      assert Value.write(Value.symbol("a\\b")) == "|a\\\\b|"
      assert Value.write(Value.symbol(<<?a, 0x7F, ?b>>)) == <<?|, ?a, 0x7F, ?b, ?|>>
    end

    test "strings" do
      assert Value.write(Value.string("hi")) == "\"hi\""
      assert Value.write(Value.string("a\"b")) == "\"a\\\"b\""
      assert Value.write(Value.string("a\\b")) == "\"a\\\\b\""
      assert Value.write(Value.string("a\nb")) == "\"a\\nb\""
      assert Value.display(Value.string("hi")) == "hi"
      assert Value.display(Value.string("a\nb")) == "a\nb"
    end

    test "strings — every named-escape char and the unicode escape" do
      assert Value.write(Value.string("a\rb")) == "\"a\\rb\""
      assert Value.write(Value.string("a\tb")) == "\"a\\tb\""
      assert Value.write(Value.string("a\bb")) == "\"a\\bb\""
      assert Value.write(Value.string(<<?a, 0x01, ?b>>)) == "\"a\\x1;b\""
    end

    test "characters" do
      assert Value.write(Value.char(?a)) == "#\\a"
      assert Value.write(Value.char(?\s)) == "#\\space"
      assert Value.write(Value.char(?\n)) == "#\\newline"
      assert Value.write(Value.char(0)) == "#\\null"
      assert Value.write(Value.char(0x1B)) == "#\\escape"
      assert Value.display(Value.char(?a)) == "a"
      assert Value.display(Value.char(?\s)) == " "
    end

    test "lists, dotted lists, nested" do
      assert Value.write(Value.list([1, 2, 3])) == "(1 2 3)"
      assert Value.write({:pair, 1, 2}) == "(1 . 2)"
      assert Value.write(Value.improper_list([1, 2], 3)) == "(1 2 . 3)"

      nested = Value.list([Value.symbol("a"), Value.list([1, 2]), Value.string("hi")])
      assert Value.write(nested) == "(a (1 2) \"hi\")"
    end

    test "vectors and bytevectors" do
      assert Value.write(Value.vector([1, 2, 3])) == "#(1 2 3)"
      assert Value.write(Value.vector([])) == "#()"
      assert Value.write(Value.bytevector([1, 2, 255])) == "#u8(1 2 255)"
      assert Value.write(Value.bytevector([])) == "#u8()"
    end

    test "procedures and records" do
      c = Value.closure([], [], %{}, "fact")
      assert Value.write(c) == "#<procedure fact>"

      anon = Value.closure([], [], %{}, nil)
      assert Value.write(anon) == "#<procedure>"

      p = Value.primitive("+", {:at_least, 0}, fn _ -> 0 end)
      assert Value.write(p) == "#<primitive +>"
    end

    test "record without a {:record_type, name, _} type-id falls back to inspect" do
      r = Value.record({:type, "p"}, {1, 2})
      assert Value.write(r) == "#<record #{inspect({:type, "p"})}>"
    end

    test "error objects render kind, message, and irritants" do
      e = {:error_obj, :user, {:string, "boom"}, []}
      assert Value.write(e) == "#<error \"boom\">"

      with_irrs = {:error_obj, :read, {:string, "bad input"}, [1, Value.symbol("x")]}
      assert Value.write(with_irrs) == "#<read-error \"bad input\" 1 x>"

      file_kind = {:error_obj, :file, {:string, "missing"}, []}
      assert Value.write(file_kind) == "#<file-error \"missing\">"
    end

    test "display falls through to write for non-string/char aggregates" do
      assert Value.display(Value.list([Value.string("hi"), Value.char(?!)])) == "(hi !)"
    end
  end

  describe "non-finite float specials" do
    @pos_inf {:float_special, :pos_inf}
    @neg_inf {:float_special, :neg_inf}
    @nan {:float_special, :nan}

    test "type predicates classify specials" do
      for v <- [@pos_inf, @neg_inf, @nan] do
        assert Value.number?(v)
        assert Value.inexact?(v)
        refute Value.exact?(v)
        refute Value.integer?(v)
        assert Value.float_special?(v)
      end

      refute Value.float_special?(1.0)
      refute Value.float_special?(1)
    end

    test "eqv? — like infinities are equal; NaN is never equal to anything" do
      assert Value.eqv?(@pos_inf, @pos_inf)
      assert Value.eqv?(@neg_inf, @neg_inf)
      refute Value.eqv?(@pos_inf, @neg_inf)
      refute Value.eqv?(@nan, @nan)
      refute Value.eqv?(@nan, 1)
      refute Value.eqv?(1, @nan)
    end

    test "equal? mirrors eqv? for specials, NaN included" do
      assert Value.equal?(@pos_inf, @pos_inf)
      refute Value.equal?(@pos_inf, @neg_inf)
      refute Value.equal?(@nan, @nan)
    end

    test "write/display render the literal forms" do
      assert Value.write(@pos_inf) == "+inf.0"
      assert Value.write(@neg_inf) == "-inf.0"
      assert Value.write(@nan) == "+nan.0"
      assert Value.display(@pos_inf) == "+inf.0"
      assert Value.display(@neg_inf) == "-inf.0"
      assert Value.display(@nan) == "+nan.0"
    end
  end
end

defmodule Schooner.Primitives.BaseStringsTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "string constructors" do
    test "(string ...) builds a string from chars" do
      assert run(~S|(string #\h #\i)|) == Value.string("hi")
      assert run("(string)") == Value.string("")
    end

    test "make-string fills with the given char" do
      assert run(~S|(make-string 3 #\x)|) == Value.string("xxx")
      assert run("(make-string 0)") == Value.string("")
    end

    test "make-string defaults to spaces" do
      assert run("(make-string 3)") == Value.string("   ")
    end

    test "make-string with non-char fill raises" do
      e = assert_raise PError, fn -> run("(make-string 3 1)") end
      assert match?({:type_error, "make-string", "char", _}, e.reason)
    end
  end

  describe "length / ref / append on UTF-8" do
    test "string-length counts codepoints, not bytes or graphemes" do
      assert run(~S|(string-length "hi")|) === 2
      # café — four codepoints, é is two bytes.
      assert run(~S|(string-length "café")|) === 4
      # Combining accent: 'e' + COMBINING ACUTE ACCENT (U+0301) = 2 codepoints.
      assert run(~s|(string-length "é")|) === 2
    end

    test "string-ref works on multi-byte UTF-8" do
      # café — index 3 is the combined é (U+00E9).
      assert run(~S|(string-ref "café" 3)|) == Value.char(0x00E9)
    end

    test "string-ref out of range raises" do
      e = assert_raise PError, fn -> run(~S|(string-ref "abc" 5)|) end
      assert match?({:index_out_of_range, "string-ref", _, _}, e.reason)
    end

    test "string-append concatenates" do
      assert run(~S|(string-append)|) == Value.string("")
      assert run(~S|(string-append "ab" "cd")|) == Value.string("abcd")
      assert run(~S|(string-append "" "x")|) == Value.string("x")
    end
  end

  describe "substring / string-copy" do
    test "substring slices by codepoint" do
      assert run(~S|(substring "abcdef" 1 4)|) == Value.string("bcd")
      assert run(~S|(substring "abc" 0 0)|) == Value.string("")
    end

    test "substring on multi-byte input" do
      assert run(~S|(substring "café" 2 4)|) == Value.string("fé")
    end

    test "substring out of range raises" do
      e = assert_raise PError, fn -> run(~S|(substring "abc" 0 10)|) end
      assert match?({:index_out_of_range, "substring", _, _}, e.reason)
    end

    test "string-copy slice" do
      assert run(~S|(string-copy "hello")|) == Value.string("hello")
      assert run(~S|(string-copy "hello" 1)|) == Value.string("ello")
      assert run(~S|(string-copy "hello" 1 3)|) == Value.string("el")
    end

    test "slicing at end-of-string boundary is allowed" do
      assert run(~S|(substring "abc" 3 3)|) == Value.string("")
      assert run(~S|(string-copy "abc" 3 3)|) == Value.string("")
      assert run(~S|(string-copy "abc" 3)|) == Value.string("")
    end

    test "negative start raises with codepoint length in the error" do
      e = assert_raise PError, fn -> run(~S|(substring "café" -1 2)|) end
      assert e.reason == {:index_out_of_range, "substring", -1, 4}
    end

    test "stop < start raises with codepoint length in the error" do
      e = assert_raise PError, fn -> run(~S|(substring "café" 3 1)|) end
      assert e.reason == {:index_out_of_range, "substring", 1, 4}
    end

    test "string-ref negative index raises with codepoint length" do
      e = assert_raise PError, fn -> run(~S|(string-ref "café" -1)|) end
      assert e.reason == {:index_out_of_range, "string-ref", -1, 4}
    end
  end

  describe "comparison" do
    test "string=?" do
      assert run(~S|(string=? "ab" "ab")|) == Value.bool(true)
      assert run(~S|(string=? "ab" "ab" "ab")|) == Value.bool(true)
      assert run(~S|(string=? "ab" "ac")|) == Value.bool(false)
    end

    test "string<? / string<=? / string>? / string>=?" do
      assert run(~S|(string<? "abc" "abd")|) == Value.bool(true)
      assert run(~S|(string<? "abc" "abc")|) == Value.bool(false)
      assert run(~S|(string<=? "abc" "abc")|) == Value.bool(true)
      assert run(~S|(string>? "b" "a")|) == Value.bool(true)
      assert run(~S|(string>=? "b" "b")|) == Value.bool(true)
    end

    test "comparison rejects non-strings" do
      e = assert_raise PError, fn -> run(~S|(string=? "ab" 1)|) end
      assert match?({:type_error, "string=?", "string", _}, e.reason)
    end
  end

  describe "string <-> list" do
    test "string->list and list->string round-trip" do
      assert run(~S|(list->string (string->list "café"))|) == Value.string("café")
      assert run(~S|(list->string '())|) == Value.string("")
    end

    test "string->list with start / end" do
      assert run(~S|(string->list "abcd" 1 3)|) ==
               Value.list([Value.char(?b), Value.char(?c)])
    end

    test "list->string demands a list of chars" do
      e = assert_raise PError, fn -> run("(list->string '(1 2 3))") end
      assert match?({:type_error, "list->string", "char", _}, e.reason)
    end
  end

  describe "case mappings" do
    test "string-upcase / string-downcase preserve unicode case rules" do
      assert run(~S|(string-upcase "abc")|) == Value.string("ABC")
      assert run(~S|(string-downcase "ABC")|) == Value.string("abc")
    end

    test "ß upcases to SS (Unicode default mapping)" do
      assert run(~s|(string-upcase "ß")|) == Value.string("SS")
    end

    test "Turkish dotless i — default mapping is locale-agnostic" do
      # `ı` (U+0131) up-cases to ASCII `I` under Unicode default rules.
      assert run(~s|(string-upcase "ı")|) == Value.string("I")
    end
  end

  # ---------------------------------------------------------------------------
  # Bytevectors
  # ---------------------------------------------------------------------------

  describe "bytevectors — constructors and length" do
    test "(bytevector ...) accepts bytes" do
      assert run("(bytevector)") == Value.bytevector([])
      assert run("(bytevector 1 2 3)") == Value.bytevector([1, 2, 3])
    end

    test "make-bytevector with fill" do
      assert run("(make-bytevector 3 0)") == Value.bytevector(<<0, 0, 0>>)
      assert run("(make-bytevector 4 255)") == Value.bytevector(<<255, 255, 255, 255>>)
    end

    test "make-bytevector default fill is 0" do
      assert run("(make-bytevector 2)") == Value.bytevector(<<0, 0>>)
    end

    test "out-of-range byte raises" do
      e = assert_raise PError, fn -> run("(bytevector 256)") end
      assert match?({:byte_out_of_range, "bytevector", _}, e.reason)
    end

    test "bytevector-length" do
      assert run("(bytevector-length #u8(1 2 3 4))") === 4
    end

    test "bytevector-u8-ref" do
      assert run("(bytevector-u8-ref #u8(10 20 30) 1)") === 20
    end

    test "bytevector-u8-ref out of range raises" do
      assert_raise PError, fn -> run("(bytevector-u8-ref #u8(1 2) 5)") end
    end
  end

  describe "bytevector copy / append" do
    test "bytevector-copy whole / range" do
      assert run("(bytevector-copy #u8(1 2 3))") == Value.bytevector(<<1, 2, 3>>)
      assert run("(bytevector-copy #u8(1 2 3 4) 1 3)") == Value.bytevector(<<2, 3>>)
    end

    test "bytevector-append" do
      assert run("(bytevector-append)") == Value.bytevector(<<>>)

      assert run("(bytevector-append #u8(1 2) #u8(3 4))") ==
               Value.bytevector(<<1, 2, 3, 4>>)
    end
  end

  describe "utf8 conversions" do
    test "string->utf8 returns the UTF-8 bytes" do
      assert run(~S|(string->utf8 "abc")|) == Value.bytevector(<<?a, ?b, ?c>>)
      # café — last codepoint U+00E9 is two bytes.
      assert run(~S|(string->utf8 "café")|) == Value.bytevector(<<?c, ?a, ?f, 0xC3, 0xA9>>)
    end

    test "utf8->string round-trips through string->utf8" do
      assert run(~S|(utf8->string (string->utf8 "café"))|) == Value.string("café")
    end

    test "utf8->string raises on invalid UTF-8" do
      # 0xC3 alone is the start of a 2-byte sequence with no continuation.
      e = assert_raise PError, fn -> run("(utf8->string #u8(195))") end
      assert e.reason == {:invalid_utf8, "utf8->string"}
    end
  end
end

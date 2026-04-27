defmodule Schooner.Primitives.CharTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "char->integer / integer->char" do
    test "ASCII round-trip" do
      assert run(~S|(char->integer #\A)|) === 65
      assert run("(integer->char 65)") == Value.char(?A)
    end

    test "non-ASCII codepoint" do
      assert run("(integer->char 233)") == Value.char(0x00E9)
      assert run(~S|(char->integer #\é)|) === 0x00E9
    end

    test "out-of-range codepoint raises" do
      e = assert_raise PError, fn -> run("(integer->char -1)") end
      assert match?({:codepoint_out_of_range, "integer->char", _}, e.reason)

      e = assert_raise PError, fn -> run("(integer->char 1114112)") end
      assert match?({:codepoint_out_of_range, "integer->char", _}, e.reason)
    end

    test "surrogate range raises" do
      e = assert_raise PError, fn -> run("(integer->char 55296)") end
      assert match?({:codepoint_out_of_range, "integer->char", _}, e.reason)
    end
  end

  describe "comparators (case-sensitive)" do
    test "char=?" do
      assert run(~S|(char=? #\a #\a)|) == Value.bool(true)
      assert run(~S|(char=? #\a #\a #\a)|) == Value.bool(true)
      assert run(~S|(char=? #\a #\b)|) == Value.bool(false)
    end

    test "char<? / char<=? / char>? / char>=?" do
      assert run(~S|(char<? #\a #\b #\c)|) == Value.bool(true)
      assert run(~S|(char<=? #\a #\a #\b)|) == Value.bool(true)
      assert run(~S|(char>? #\c #\b #\a)|) == Value.bool(true)
      assert run(~S|(char>=? #\b #\b #\a)|) == Value.bool(true)
    end
  end

  describe "comparators (case-insensitive)" do
    test "char-ci=? folds case before comparing" do
      assert run(~S|(char-ci=? #\A #\a)|) == Value.bool(true)
      assert run(~S|(char-ci=? #\A #\b)|) == Value.bool(false)
    end

    test "char-ci<?" do
      assert run(~S|(char-ci<? #\A #\b #\C)|) == Value.bool(true)
    end

    test "char-ci<=? / char-ci>? / char-ci>=?" do
      assert run(~S|(char-ci<=? #\A #\a #\b)|) == Value.bool(true)
      assert run(~S|(char-ci>? #\C #\b #\A)|) == Value.bool(true)
      assert run(~S|(char-ci>=? #\B #\b #\A)|) == Value.bool(true)
    end
  end

  describe "case mappings" do
    test "char-upcase / char-downcase on ASCII" do
      assert run(~S|(char-upcase #\a)|) == Value.char(?A)
      assert run(~S|(char-downcase #\A)|) == Value.char(?a)
    end

    test "char-foldcase folds to a canonical form" do
      assert run(~S|(char=? (char-foldcase #\A) (char-foldcase #\a))|) ==
               Value.bool(true)
    end

    test "ß has no single-codepoint upcase — char-upcase leaves it unchanged" do
      assert run(~s|(char-upcase #\\ß)|) == Value.char(0x00DF)
    end

    test "char-foldcase on a multi-codepoint fold leaves the original char unchanged" do
      # ß folds to "ss" — two codepoints — so char-foldcase keeps ß.
      assert run(~s|(char-foldcase #\\ß)|) == Value.char(0x00DF)
    end
  end

  describe "category predicates" do
    test "char-alphabetic?" do
      assert run(~S|(char-alphabetic? #\a)|) == Value.bool(true)
      assert run(~S|(char-alphabetic? #\Z)|) == Value.bool(true)
      assert run(~S|(char-alphabetic? #\1)|) == Value.bool(false)
      assert run(~S|(char-alphabetic? #\space)|) == Value.bool(false)
    end

    test "char-numeric?" do
      assert run(~S|(char-numeric? #\0)|) == Value.bool(true)
      assert run(~S|(char-numeric? #\9)|) == Value.bool(true)
      assert run(~S|(char-numeric? #\a)|) == Value.bool(false)
    end

    test "char-whitespace?" do
      assert run(~S|(char-whitespace? #\space)|) == Value.bool(true)
      assert run(~S|(char-whitespace? #\newline)|) == Value.bool(true)
      assert run(~S|(char-whitespace? #\tab)|) == Value.bool(true)
      assert run(~S|(char-whitespace? #\a)|) == Value.bool(false)
    end

    test "char-upper-case? / char-lower-case?" do
      assert run(~S|(char-upper-case? #\A)|) == Value.bool(true)
      assert run(~S|(char-upper-case? #\a)|) == Value.bool(false)
      assert run(~S|(char-lower-case? #\a)|) == Value.bool(true)
      assert run(~S|(char-lower-case? #\A)|) == Value.bool(false)
    end

    test "non-ASCII categories use the Unicode regexes" do
      # Latin letter with diacritic — alphabetic and lower-case.
      assert run(~s|(char-alphabetic? #\\é)|) == Value.bool(true)
      assert run(~s|(char-lower-case? #\\é)|) == Value.bool(true)
      assert run(~s|(char-upper-case? #\\é)|) == Value.bool(false)

      # Latin capital N-tilde — upper-case.
      assert run(~s|(char-upper-case? #\\Ñ)|) == Value.bool(true)

      # Arabic-Indic digit five — numeric outside ?0..?9.
      assert run("(char-numeric? (integer->char #x0665))") == Value.bool(true)

      # No-break space — whitespace outside the ASCII set.
      assert run("(char-whitespace? (integer->char #x00A0))") == Value.bool(true)

      # Emoji — neither alphabetic nor numeric nor whitespace nor cased.
      assert run("(char-alphabetic? (integer->char #x1F600))") == Value.bool(false)
      assert run("(char-numeric? (integer->char #x1F600))") == Value.bool(false)
      assert run("(char-whitespace? (integer->char #x1F600))") == Value.bool(false)
      assert run("(char-upper-case? (integer->char #x1F600))") == Value.bool(false)
      assert run("(char-lower-case? (integer->char #x1F600))") == Value.bool(false)
    end
  end

  describe "type errors" do
    test "comparator rejects non-char arg" do
      e = assert_raise PError, fn -> run(~S|(char=? #\a 1)|) end
      assert match?({:type_error, "char=?", "char", _}, e.reason)
    end

    test "case mapping rejects non-char arg" do
      e = assert_raise PError, fn -> run("(char-upcase 1)") end
      assert match?({:type_error, "char-upcase", "char", _}, e.reason)
    end

    test "char->integer rejects non-char arg" do
      e = assert_raise PError, fn -> run("(char->integer 1)") end
      assert match?({:type_error, "char->integer", "char", _}, e.reason)
    end

    test "integer->char rejects non-integer arg" do
      e = assert_raise PError, fn -> run(~S|(integer->char "x")|) end
      assert match?({:type_error, "integer->char", "integer", _}, e.reason)
    end

    test "char-downcase / char-foldcase reject non-char arg" do
      e = assert_raise PError, fn -> run("(char-downcase 1)") end
      assert match?({:type_error, "char-downcase", "char", _}, e.reason)

      e = assert_raise PError, fn -> run("(char-foldcase 1)") end
      assert match?({:type_error, "char-foldcase", "char", _}, e.reason)
    end

    test "category predicates reject non-char arg" do
      for op <- [
            "char-alphabetic?",
            "char-numeric?",
            "char-whitespace?",
            "char-upper-case?",
            "char-lower-case?"
          ] do
        e = assert_raise PError, fn -> run("(#{op} 1)") end
        assert match?({:type_error, ^op, "char", _}, e.reason)
      end
    end
  end
end

defmodule Schooner.PrettyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Schooner.Pretty
  alias Schooner.Reader
  alias Schooner.Test.ValueGenerators
  alias Schooner.Value

  doctest Schooner.Pretty

  defp read!(source) do
    [datum] = Reader.read_string(source)
    datum
  end

  defp format(source, opts), do: source |> read!() |> Pretty.format(opts)

  # A symbol with the hygiene marks `marks`, as expansion renames it.
  defp marked(base, marks), do: {:sym, Enum.join([base | marks], <<0>>)}

  describe "layout" do
    test "a form that fits is printed on one line" do
      assert format("(define (f x) (if x 'a `(b ,x ,@x)))", []) ==
               "(define (f x) (if x 'a `(b ,x ,@x)))"
    end

    test "a body form keeps its first arguments on the first line and indents its body" do
      assert format("(lambda (x y) (display x) (display y))", width: 20) == """
             (lambda (x y)
               (display x)
               (display y))\
             """

      assert format("(let loop ((i 0)) (loop (+ i 1)))", width: 20) == """
             (let loop ((i 0))
               (loop (+ i 1)))\
             """

      assert format("(do ((i 0 (+ i 1))) ((= i 3)) (f i))", width: 30) == """
             (do ((i 0 (+ i 1))) ((= i 3))
               (f i))\
             """

      assert format("(begin (first-thing) (second-thing))", width: 20) == """
             (begin
               (first-thing)
               (second-thing))\
             """
    end

    test "first arguments that don't fit on the first line are indented by four" do
      assert format("(do ((index 0 (+ index 1))) ((= index 3)) (f index))", width: 30) == """
             (do ((index 0 (+ index 1)))
                 ((= index 3))
               (f index))\
             """
    end

    test "a call lines its arguments up under the first" do
      assert format("(if (> x 0) (positive-thing x) (negative-thing x))", width: 30) == """
             (if (> x 0)
                 (positive-thing x)
                 (negative-thing x))\
             """
    end

    test "a first argument that fits only on its own line puts each item on its own line" do
      assert format("(abcdefghij (x y))", width: 14) == """
             (abcdefghij
              (x y))\
             """
    end

    test "a list that doesn't start with a symbol puts each item on its own line" do
      assert format("((lambda (x) (f x)) argument-one argument-two)", width: 30) == """
             ((lambda (x) (f x))
              argument-one
              argument-two)\
             """
    end

    test "nested forms are laid out at their own column" do
      assert format("(define (f x) (cond ((> x 0) 'positive) ((< x 0) 'negative) (else 'zero)))",
               width: 40
             ) == """
             (define (f x)
               (cond ((> x 0) 'positive)
                     ((< x 0) 'negative)
                     (else 'zero)))\
             """
    end

    test "improper lists, vectors and abbreviations" do
      assert format("(alpha beta gamma . delta)", width: 10) == """
             (alpha
              beta
              gamma
              . delta)\
             """

      assert format("#(alpha beta gamma)", width: 10) == """
             #(alpha
               beta
               gamma)\
             """

      assert format("'(alpha beta gamma)", width: 10) == """
             '(alpha
               beta
               gamma)\
             """

      assert format("'(alpha beta gamma)", width: 16) == """
             '(alpha beta
                     gamma)\
             """
    end

    test "closing delimiters count towards the width" do
      assert format("(f abcdefg)", width: 10) == "(f\n abcdefg)"

      assert format("(define (f) (g (h x)))", width: 15) == """
             (define (f)
               (g (h x)))\
             """

      assert format("(define (f) (g (h x)))", width: 11) == """
             (define (f)
               (g
                (h x)))\
             """
    end

    test "an atom too long for the width is printed anyway" do
      assert format("a-very-long-symbol", width: 5) == "a-very-long-symbol"
      assert format("(f a-very-long-symbol)", width: 5) == "(f\n a-very-long-symbol)"
    end

    test "atoms are written as Value.write writes them" do
      source = ~S{(f "a\nb" #\space 1/2 -1.5 #u8(1 2) |a b| #t ())}
      assert format(source, []) == source
    end

    test "a symbol starting with @ is quoted, so an unquote of it reads back" do
      for width <- [80, 5] do
        assert format("(unquote |@foo|)", width: width) == ",|@foo|"
        assert read!(format("(unquote |@foo|)", width: width)) == read!("(unquote |@foo|)")
      end
    end

    test "only (quote x) with one datum is abbreviated" do
      assert format("(quote a b)", []) == "(quote a b)"
      assert format("(quote)", []) == "(quote)"
      assert format("(quote . a)", []) == "(quote . a)"
    end
  end

  describe "renamed identifiers" do
    test "are printed with their marks, or plain" do
      form = Value.list([marked("tmp", ["1"]), {:sym, "tmp"}, marked("x", ["2", "3"])])

      assert Pretty.format(form) == "(tmp·1 tmp x·2·3)"
      assert Pretty.format(form, names: :plain) == "(tmp tmp x)"
    end

    test "a name of the script's own that looks renamed is quoted" do
      form = Value.list([marked("t", ["1"]), {:sym, "t·1"}])
      assert Pretty.format(form) == "(t·1 |t·1|)"
      assert Pretty.format(form, names: :plain) == "(t t·1)"
      assert Reader.read_string("|t·1|") == [{:sym, "t·1"}]
    end

    test "a marked name that needs quoting is quoted whole" do
      form = Value.list([{:sym, "lambda"}, Value.list([marked("a b", ["1"])]), 1])
      assert Pretty.format(form) == "(lambda (|a b·1|) 1)"
      assert Pretty.format(form, names: :plain) == "(lambda (|a b|) 1)"
    end

    test "a marked body form is indented as the form" do
      form = read!("(letrec* ((loop (lambda () (loop)))) (loop))")
      form = [marked("letrec*", ["1"]) | tl(form)]

      assert Pretty.format(form, width: 40) == """
             (letrec*·1 ((loop (lambda () (loop))))
               (loop))\
             """
    end

    test "a marked quote is not abbreviated" do
      assert Pretty.format(Value.list([marked("quote", ["1"]), {:sym, "a"}])) == "(quote·1 a)"
    end
  end

  test "the record type in an expanded define-record-type" do
    environment = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
    {:ok, [form]} = Schooner.expand("(define-record-type p (mk) p?)", environment)

    assert Pretty.format(form, width: 1000) ==
             "(begin (define (mk) (%record-instance #<record-type p>)) " <>
               "(define (p? v) (%record-of? #<record-type p> v)))"
  end

  test "invalid options raise" do
    assert_raise ArgumentError, ~r/:width/, fn -> Pretty.format(1, width: 0) end
    assert_raise ArgumentError, ~r/:names/, fn -> Pretty.format(1, names: :bare) end
    assert_raise ArgumentError, ~r/unknown keys/, fn -> Pretty.format(1, indent: 2) end
  end

  describe "round trip" do
    # Code-shaped data: lists headed by the symbols the printer lays
    # out specially, and the abbreviated forms, over readable values.
    defp code(depth \\ 3) do
      head =
        member_of(~w(define lambda let do begin if quote quasiquote unquote unquote-splicing f))

      leaf = ValueGenerators.readable_value(1)

      if depth == 0 do
        leaf
      else
        one_of([
          leaf,
          bind(head, fn h ->
            map(list_of(code(depth - 1), max_length: 5), &Value.list([{:sym, h} | &1]))
          end),
          map(list_of(code(depth - 1), max_length: 5), &Value.list/1),
          map(list_of(code(depth - 1), max_length: 3), &Value.vector/1)
        ])
      end
    end

    property "reading the output gives a datum equal? to the input, at any width" do
      check all(
              datum <- one_of([ValueGenerators.readable_value(), code()]),
              width <- integer(1..100)
            ) do
        output = Pretty.format(datum, width: width)
        assert [read_back] = Reader.read_string(output)
        assert Value.equal?(datum, read_back), "#{inspect(datum)} printed as\n#{output}"
      end
    end

    property "with plain names, reading the output gives the datum without its marks" do
      check all(datum <- code(), width <- integer(1..100), mark <- integer(1..3)) do
        marked = mark_symbols(datum, mark)

        assert [read_back] =
                 Reader.read_string(Pretty.format(marked, width: width, names: :plain))

        assert Value.equal?(datum, read_back)
      end
    end

    defp mark_symbols({:sym, "quote" <> _} = sym, _mark), do: sym
    defp mark_symbols({:sym, "quasiquote"} = sym, _mark), do: sym
    defp mark_symbols({:sym, "unquote" <> _} = sym, _mark), do: sym
    defp mark_symbols({:sym, name}, mark), do: marked(name, [Integer.to_string(mark)])
    defp mark_symbols([h | t], mark), do: [mark_symbols(h, mark) | mark_symbols(t, mark)]

    defp mark_symbols({:vector, items}, mark),
      do:
        {:vector,
         items |> Tuple.to_list() |> Enum.map(&mark_symbols(&1, mark)) |> List.to_tuple()}

    defp mark_symbols(other, _mark), do: other
  end
end

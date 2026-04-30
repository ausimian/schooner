defmodule Schooner.Primitives.BasePairsTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "cons / car / cdr" do
    test "cons builds a pair, car/cdr destructure it" do
      assert run("(cons 1 2)") == [1 | 2]
      assert run("(car (cons 1 2))") == 1
      assert run("(cdr (cons 1 2))") == 2
    end

    test "car/cdr on non-pair raise type_error" do
      e = assert_raise PError, fn -> run("(car 1)") end
      assert match?({:type_error, "car", "pair", _}, e.reason)

      e = assert_raise PError, fn -> run("(cdr '())") end
      assert match?({:type_error, "cdr", "pair", _}, e.reason)
    end
  end

  describe "list constructors and predicates" do
    test "(list ...) builds proper lists" do
      assert run("(list)") == []
      assert run("(list 1 2 3)") == Value.list([1, 2, 3])
    end

    test "list? recognises proper lists, rejects improper and atoms" do
      assert run("(list? '())") == Value.bool(true)
      assert run("(list? '(1 2 3))") == Value.bool(true)
      assert run("(list? (cons 1 2))") == Value.bool(false)
      assert run("(list? 42)") == Value.bool(false)
      assert run("(list? \"abc\")") == Value.bool(false)
    end

    test "list-copy returns a structurally equal list" do
      assert run("(list-copy '(1 2 3))") == Value.list([1, 2, 3])
      assert run("(list-copy '())") == []
    end

    test "list-copy preserves an improper tail (r7rs §6.4)" do
      assert run("(list-copy (cons 1 2))") == [1 | 2]
      assert run("(list-copy '(6 7 8 . 9))") == [6, 7, 8 | 9]
    end

    test "list-copy spine is fresh — eq? distinguishes copy from source" do
      # Each spine cons is freshly allocated, so identity-aware `eq?`
      # separates the copy from the source. Element identity is
      # preserved (the elements are shared, not cloned).
      assert run("(let ((l '(1 2 3))) (eq? l (list-copy l)))") == Value.bool(false)
      assert run("(let ((l '(1 2 3))) (equal? l (list-copy l)))") == Value.bool(true)

      assert run("(let* ((a (list 'x)) (l (list a))) (eq? a (car (list-copy l))))") ==
               Value.bool(true)
    end

    test "freshly consed pairs are not eq? to a structurally equal pair" do
      assert run("(eq? (cons 1 2) (cons 1 2))") == Value.bool(false)
      assert run("(let ((p (cons 1 2))) (eq? p p))") == Value.bool(true)
    end
  end

  describe "length / reverse" do
    test "length of empty, single-element, and long lists" do
      assert run("(length '())") === 0
      assert run("(length '(7))") === 1
      assert run("(length '(1 2 3 4 5))") === 5
    end

    test "length on improper list raises" do
      e = assert_raise PError, fn -> run("(length (cons 1 2))") end
      assert match?({:improper_list, "length", _}, e.reason)
    end

    test "reverse" do
      assert run("(reverse '())") == []
      assert run("(reverse '(1))") == Value.list([1])
      assert run("(reverse '(1 2 3))") == Value.list([3, 2, 1])
    end

    test "reverse on improper list raises" do
      e = assert_raise PError, fn -> run("(reverse (cons 1 2))") end
      assert match?({:improper_list, "reverse", _}, e.reason)
    end
  end

  describe "append" do
    test "append of zero, one, many" do
      assert run("(append)") == []
      assert run("(append '(1 2 3))") == Value.list([1, 2, 3])
      assert run("(append '(1 2) '(3 4))") == Value.list([1, 2, 3, 4])
      assert run("(append '(1) '(2) '(3))") == Value.list([1, 2, 3])
      assert run("(append '() '(1 2))") == Value.list([1, 2])
    end

    test "last argument may be any value (allows building improper tails)" do
      assert run("(append '(1 2) 3)") == [1 | [2 | 3]]
      assert run("(append '() 7)") == 7
    end

    test "non-final improper list raises" do
      e = assert_raise PError, fn -> run("(append (cons 1 2) '(3))") end
      assert match?({:improper_list, "append", _}, e.reason)
    end

    test "appending a 100k-element list does not blow the stack" do
      result =
        run("""
        (let ((xs (vector->list (make-vector 100000 0))))
          (length (append xs '(a b c))))
        """)

      assert result == 100_003
    end
  end

  describe "list-tail / list-ref" do
    test "list-tail" do
      assert run("(list-tail '(a b c d) 0)") ==
               Value.list([
                 Value.symbol("a"),
                 Value.symbol("b"),
                 Value.symbol("c"),
                 Value.symbol("d")
               ])

      assert run("(list-tail '(a b c d) 2)") == Value.list([Value.symbol("c"), Value.symbol("d")])
      assert run("(list-tail '(1 2 3) 3)") == []
    end

    test "list-tail past end raises index_out_of_range" do
      e = assert_raise PError, fn -> run("(list-tail '(1 2) 5)") end
      assert match?({:index_out_of_range, "list-tail", _, _}, e.reason)
    end

    test "list-ref" do
      assert run("(list-ref '(a b c) 0)") == Value.symbol("a")
      assert run("(list-ref '(a b c) 2)") == Value.symbol("c")
    end

    test "list-ref past end raises" do
      e = assert_raise PError, fn -> run("(list-ref '(1 2) 5)") end
      assert match?({:index_out_of_range, "list-ref", _, _}, e.reason)
    end

    test "negative index raises" do
      assert_raise PError, fn -> run("(list-ref '(1 2 3) -1)") end
      assert_raise PError, fn -> run("(list-tail '(1 2 3) -1)") end
    end
  end

  describe "member / memv / memq" do
    test "member uses equal?" do
      assert run(~S|(member "abc" (list "a" "abc" "c"))|) ==
               Value.list([Value.string("abc"), Value.string("c")])

      assert run(~S|(member "z" (list "a" "b"))|) == Value.bool(false)
    end

    test "memv uses eqv?" do
      assert run("(memv 2 '(1 2 3))") == Value.list([2, 3])
      assert run("(memv 2.0 '(1 2 3))") == Value.bool(false)
    end

    test "memq uses eq?" do
      assert run("(memq 'b '(a b c))") == Value.list([Value.symbol("b"), Value.symbol("c")])
      assert run("(memq 'z '(a b c))") == Value.bool(false)
    end
  end

  describe "assoc / assv / assq" do
    test "assoc finds an entry by equal?" do
      assert run(~S|(assoc "b" (list (list "a" 1) (list "b" 2) (list "c" 3)))|) ==
               Value.list([Value.string("b"), 2])
    end

    test "assv finds an entry by eqv?" do
      assert run("(assv 2 '((1 one) (2 two) (3 three)))") ==
               Value.list([2, Value.symbol("two")])
    end

    test "assq finds by eq? on symbols" do
      assert run("(assq 'b '((a 1) (b 2) (c 3)))") ==
               Value.list([Value.symbol("b"), 2])
    end

    test "missing key returns #f" do
      assert run("(assoc 'z '((a 1) (b 2)))") == Value.bool(false)
      assert run("(assq 'z '())") == Value.bool(false)
    end
  end

  describe "map / for-each" do
    test "map with one list" do
      assert run("(map (lambda (x) (* x x)) '(1 2 3 4))") ==
               Value.list([1, 4, 9, 16])
    end

    test "map with multiple lists stops at the shortest" do
      assert run("(map + '(1 2 3) '(10 20 30 40))") ==
               Value.list([11, 22, 33])
    end

    test "for-each returns :unspecified" do
      # Mutation is out of scope, so we cannot observe side effects from a
      # Scheme-side accumulator. We assert the return contract instead and
      # rely on `map`'s parallel test for evidence that the proc is invoked.
      assert run("(for-each (lambda (x) x) '(1 2 3))") == :unspecified
    end

    test "map and for-each demand procedures" do
      e = assert_raise PError, fn -> run("(map 1 '(1 2 3))") end
      assert match?({:type_error, "map", "procedure", _}, e.reason)

      e = assert_raise PError, fn -> run("(for-each 1 '(1 2 3))") end
      assert match?({:type_error, "for-each", "procedure", _}, e.reason)
    end
  end

  describe "apply" do
    test "applies a procedure to a list of args" do
      assert run("(apply + '(1 2 3 4))") == 10
      assert run("(apply list '())") == []
    end

    test "splices a trailing list after positional leading args" do
      assert run("(apply + 1 2 '(3 4 5))") == 15

      assert run("(apply list 'a 'b '(c d))") ==
               Value.list([
                 Value.symbol("a"),
                 Value.symbol("b"),
                 Value.symbol("c"),
                 Value.symbol("d")
               ])
    end

    test "works with closures" do
      assert run("(apply (lambda (x y z) (* x y z)) '(2 3 4))") == 24
    end

    test "rejects a non-procedure first argument" do
      e = assert_raise PError, fn -> run("(apply 1 '())") end
      assert match?({:type_error, "apply", "procedure", _}, e.reason)
    end

    test "rejects an improper list as the trailing argument" do
      e = assert_raise PError, fn -> run("(apply + '(1 2 . 3))") end
      assert match?({:improper_list, "apply", _}, e.reason)
    end
  end
end

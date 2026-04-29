defmodule Schooner.Conformance.R7rsSection4Test do
  # Worked examples from r7rs-small §4 (expressions). Each test
  # transcribes a `(form) ==> result` example from the spec verbatim;
  # any deviation is a conformance failure.
  #
  # Examples requiring features not yet in Schooner are skipped with
  # a one-line reason so phase 15's conformance pass can sweep them
  # back in once the dependencies land:
  #   - mutation (set!, vector-set!, string-set!): out of scope
  #   - internal define / body splicing: phase 8
  #   - `define-values`: not implemented (would need a non-mutating
  #     splice in the body desugarer)
  #   - delayed evaluation (delay, force, make-promise): phase 13
  #   - dynamic bindings (parameterize, make-parameter): out of scope
  #   - exception handling (guard, raise): phase 11
  #   - file ports / read-line: out of scope; `display`, `write`,
  #     `newline`, `write-string` are present in the string-port flavour
  #     (return rendered text instead of writing to a port)
  use ExUnit.Case, async: true

  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  # --- §4.1.2 — Literal expressions -----------------------------------------

  describe "§4.1.2 literal expressions" do
    test "(quote a) ==> a" do
      assert run("(quote a)") == Value.symbol("a")
    end

    test "'a ==> a" do
      assert run("'a") == Value.symbol("a")
    end

    test "'#(a b c) ==> #(a b c)" do
      assert run("'#(a b c)") ==
               Value.vector([Value.symbol("a"), Value.symbol("b"), Value.symbol("c")])
    end

    test "'() ==> ()" do
      assert run("'()") == []
    end

    test "'(+ 1 2) ==> (+ 1 2)" do
      assert run("'(+ 1 2)") == Value.list([Value.symbol("+"), 1, 2])
    end

    test "'(quote a) ==> (quote a)" do
      assert run("'(quote a)") == Value.list([Value.symbol("quote"), Value.symbol("a")])
    end

    test "''a ==> (quote a)" do
      assert run("''a") == Value.list([Value.symbol("quote"), Value.symbol("a")])
    end

    test ~S|'"abc" ==> "abc"| do
      assert run(~S|'"abc"|) == Value.string("abc")
    end

    test ~S|"abc" ==> "abc"| do
      assert run(~S|"abc"|) == Value.string("abc")
    end

    test "145932 ==> 145932" do
      assert run("145932") == 145_932
    end

    test "'145932 ==> 145932" do
      assert run("'145932") == 145_932
    end

    test "#t ==> #t" do
      assert run("#t") == Value.bool(true)
    end

    test "'#t ==> #t" do
      assert run("'#t") == Value.bool(true)
    end
  end

  # --- §4.1.3 — Procedure calls ---------------------------------------------

  describe "§4.1.3 procedure calls" do
    test "(+ 3 4) ==> 7" do
      assert run("(+ 3 4)") == 7
    end

    test "((if #f + *) 3 4) ==> 12" do
      assert run("((if #f + *) 3 4)") == 12
    end
  end

  # --- §4.1.4 — Procedures --------------------------------------------------

  describe "§4.1.4 procedures" do
    test "(lambda (x) (+ x x)) evaluates to a procedure" do
      assert match?({:closure, _, _, _, _}, run("(lambda (x) (+ x x))"))
    end

    test "((lambda (x) (+ x x)) 4) ==> 8" do
      assert run("((lambda (x) (+ x x)) 4)") == 8
    end

    # Spec uses (define reverse-subtract …); phrased here as let to keep the
    # example self-contained without leaning on top-level define.
    test "let-bound reverse-subtract: (reverse-subtract 7 10) ==> 3" do
      assert run("""
             (let ((reverse-subtract (lambda (x y) (- y x))))
               (reverse-subtract 7 10))
             """) == 3
    end

    # Spec example: (define add4 (let ((x 4)) (lambda (y) (+ x y))))
    test "closure-based add4: (add4 6) ==> 10" do
      assert run("""
             (let ((add4 (let ((x 4)) (lambda (y) (+ x y)))))
               (add4 6))
             """) == 10
    end

    test "((lambda x x) 3 4 5 6) ==> (3 4 5 6)" do
      assert run("((lambda x x) 3 4 5 6)") == Value.list([3, 4, 5, 6])
    end

    test "((lambda (x y . z) z) 3 4 5 6) ==> (5 6)" do
      assert run("((lambda (x y . z) z) 3 4 5 6)") == Value.list([5, 6])
    end
  end

  # --- §4.1.5 — Conditionals ------------------------------------------------

  describe "§4.1.5 if" do
    test "(if (> 3 2) 'yes 'no) ==> yes" do
      assert run("(if (> 3 2) 'yes 'no)") == Value.symbol("yes")
    end

    test "(if (> 2 3) 'yes 'no) ==> no" do
      assert run("(if (> 2 3) 'yes 'no)") == Value.symbol("no")
    end

    test "(if (> 3 2) (- 3 2) (+ 3 2)) ==> 1" do
      assert run("(if (> 3 2) (- 3 2) (+ 3 2))") == 1
    end
  end

  # --- §4.2.1 — Conditionals (derived) --------------------------------------

  describe "§4.2.1 cond" do
    test "(cond ((> 3 2) 'greater) ((< 3 2) 'less)) ==> greater" do
      assert run("(cond ((> 3 2) 'greater) ((< 3 2) 'less))") == Value.symbol("greater")
    end

    test "(cond ((> 3 3) 'greater) ((< 3 3) 'less) (else 'equal)) ==> equal" do
      assert run("(cond ((> 3 3) 'greater) ((< 3 3) 'less) (else 'equal))") ==
               Value.symbol("equal")
    end

    test "(cond ((assv 'b '((a 1) (b 2))) => cadr) (else #f)) ==> 2" do
      assert run("(cond ((assv 'b '((a 1) (b 2))) => cadr) (else #f))") == 2
    end
  end

  describe "§4.2.1 case" do
    test "(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite)) ==> composite" do
      assert run("(case (* 2 3) ((2 3 5 7) 'prime) ((1 4 6 8 9) 'composite))") ==
               Value.symbol("composite")
    end

    test "(case (car '(c d)) ((a) 'a) ((b) 'b)) ==> unspecified" do
      assert run("(case (car '(c d)) ((a) 'a) ((b) 'b))") == :unspecified
    end

    test "case with else => arrow returns the key" do
      assert run("""
             (case (car '(c d))
               ((a e i o u) 'vowel)
               ((w y) 'semivowel)
               (else => (lambda (x) x)))
             """) == Value.symbol("c")
    end
  end

  describe "§4.2.1 and" do
    test "(and (= 2 2) (> 2 1)) ==> #t" do
      assert run("(and (= 2 2) (> 2 1))") == Value.bool(true)
    end

    test "(and (= 2 2) (< 2 1)) ==> #f" do
      assert run("(and (= 2 2) (< 2 1))") == Value.bool(false)
    end

    test "(and 1 2 'c '(f g)) ==> (f g)" do
      assert run("(and 1 2 'c '(f g))") == Value.list([Value.symbol("f"), Value.symbol("g")])
    end

    test "(and) ==> #t" do
      assert run("(and)") == Value.bool(true)
    end
  end

  describe "§4.2.1 or" do
    test "(or (= 2 2) (> 2 1)) ==> #t" do
      assert run("(or (= 2 2) (> 2 1))") == Value.bool(true)
    end

    test "(or (= 2 2) (< 2 1)) ==> #t" do
      assert run("(or (= 2 2) (< 2 1))") == Value.bool(true)
    end

    test "(or #f #f #f) ==> #f" do
      assert run("(or #f #f #f)") == Value.bool(false)
    end

    test "(or (memq 'b '(a b c)) (/ 3 0)) ==> (b c) — short-circuits before the divide" do
      assert run("(or (memq 'b '(a b c)) (/ 3 0))") ==
               Value.list([Value.symbol("b"), Value.symbol("c")])
    end
  end

  # §4.2.1 when/unless: spec examples use display side-effects; we check the
  # return value (:unspecified on the dispatched branch) without I/O.
  describe "§4.2.1 when / unless" do
    test "when on a truthy test runs the body and returns its last value" do
      assert run("(when (= 1 1) 'a 'b)") == Value.symbol("b")
    end

    test "when on a falsy test returns :unspecified" do
      assert run("(when (= 1 2) 'a 'b)") == :unspecified
    end

    test "unless mirrors when" do
      assert run("(unless (= 1 2) 'a 'b)") == Value.symbol("b")
      assert run("(unless (= 1 1) 'a 'b)") == :unspecified
    end
  end

  # --- §4.2.2 — Binding constructs ------------------------------------------

  describe "§4.2.2 let" do
    test "(let ((x 2) (y 3)) (* x y)) ==> 6" do
      assert run("(let ((x 2) (y 3)) (* x y))") == 6
    end

    test "nested let with init expressions in the outer scope" do
      assert run("""
             (let ((x 2) (y 3))
               (let ((x 7)
                     (z (+ x y)))
                 (* z x)))
             """) == 35
    end
  end

  describe "§4.2.2 let*" do
    test "let* lets later bindings see earlier ones" do
      assert run("""
             (let ((x 2) (y 3))
               (let* ((x 7)
                      (z (+ x y)))
                 (* z x)))
             """) == 70
    end
  end

  describe "§4.2.2 letrec" do
    test "mutually recursive even?/odd? via letrec ==> #t" do
      assert run("""
             (letrec ((even?
                       (lambda (n)
                         (if (zero? n) #t (odd? (- n 1)))))
                      (odd?
                       (lambda (n)
                         (if (zero? n) #f (even? (- n 1))))))
               (even? 88))
             """) == Value.bool(true)
    end
  end

  describe "§4.2.2 letrec*" do
    test "letrec* preserves left-to-right init order with forward closures" do
      assert run("""
             (letrec* ((p (lambda (x) (+ 1 (q (- x 1)))))
                       (q (lambda (y) (if (zero? y) 0 (+ 1 (p (- y 1))))))
                       (x (p 5))
                       (y x))
               y)
             """) == 5
    end
  end

  # --- §4.2.4 — Iteration ---------------------------------------------------

  # The spec's first do example uses vector-set!, which is excluded by
  # Schooner's no-mutation constraint. The second example below sums a list.
  describe "§4.2.4 do" do
    test "summing a list with do ==> 25" do
      assert run("""
             (let ((x '(1 3 5 7 9)))
               (do ((x x (cdr x))
                    (sum 0 (+ sum (car x))))
                   ((null? x) sum)))
             """) == 25
    end
  end

  describe "§4.2.4 named let" do
    test "partition into nonneg/neg lists" do
      assert run("""
             (let loop ((numbers '(3 -2 1 6 -5))
                        (nonneg '())
                        (neg '()))
               (cond ((null? numbers) (list nonneg neg))
                     ((>= (car numbers) 0)
                      (loop (cdr numbers)
                            (cons (car numbers) nonneg)
                            neg))
                     ((< (car numbers) 0)
                      (loop (cdr numbers)
                            nonneg
                            (cons (car numbers) neg)))))
             """) ==
               Value.list([
                 Value.list([6, 1, 3]),
                 Value.list([-5, -2])
               ])
    end
  end

  # --- §4.2.8 — Quasiquotation ----------------------------------------------

  describe "§4.2.8 quasiquote" do
    test "`(list ,(+ 1 2) 4) ==> (list 3 4)" do
      assert run("`(list ,(+ 1 2) 4)") == Value.list([Value.symbol("list"), 3, 4])
    end

    test "(let ((name 'a)) `(list ,name ',name)) ==> (list a (quote a))" do
      assert run("(let ((name 'a)) `(list ,name ',name))") ==
               Value.list([
                 Value.symbol("list"),
                 Value.symbol("a"),
                 Value.list([Value.symbol("quote"), Value.symbol("a")])
               ])
    end

    test "`(a ,(+ 1 2) ,@(map abs '(4 -5 6)) b) ==> (a 3 4 5 6 b)" do
      assert run("`(a ,(+ 1 2) ,@(map abs '(4 -5 6)) b)") ==
               Value.list([Value.symbol("a"), 3, 4, 5, 6, Value.symbol("b")])
    end

    test "`#(10 5 ,(* 2 3) ,@(map + '(2 3) '(2 3)) 8) ==> #(10 5 6 4 6 8)" do
      assert run("`#(10 5 ,(* 2 3) ,@(map + '(2 3) '(2 3)) 8)") ==
               Value.vector([10, 5, 6, 4, 6, 8])
    end

    test "nested quasiquote — inner unquote stays at level 2 unchanged" do
      assert run("`(a `(b ,(+ 1 2) ,(foo ,(+ 1 3) d) e) f)") ==
               Value.list([
                 Value.symbol("a"),
                 Value.list([
                   Value.symbol("quasiquote"),
                   Value.list([
                     Value.symbol("b"),
                     Value.list([Value.symbol("unquote"), Value.list([Value.symbol("+"), 1, 2])]),
                     Value.list([
                       Value.symbol("unquote"),
                       Value.list([Value.symbol("foo"), 4, Value.symbol("d")])
                     ]),
                     Value.symbol("e")
                   ])
                 ]),
                 Value.symbol("f")
               ])
    end

    test "double-comma collapses two levels — inner ,, fires at the inner quasi" do
      assert run("(let ((name1 'x) (name2 'y)) `(a `(b ,,name1 ,',name2 d) e))") ==
               Value.list([
                 Value.symbol("a"),
                 Value.list([
                   Value.symbol("quasiquote"),
                   Value.list([
                     Value.symbol("b"),
                     Value.list([Value.symbol("unquote"), Value.symbol("x")]),
                     Value.list([
                       Value.symbol("unquote"),
                       Value.list([Value.symbol("quote"), Value.symbol("y")])
                     ]),
                     Value.symbol("d")
                   ])
                 ]),
                 Value.symbol("e")
               ])
    end
  end
end

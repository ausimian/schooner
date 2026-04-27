defmodule Schooner.ExpanderTest do
  # Phase 9 — hygienic `syntax-rules` expander. End-to-end tests that
  # exercise the expander through `Schooner.run/1`. Tests for the
  # pattern matcher, template instantiator, and individual transformer
  # behaviour live in dedicated files alongside this one.
  use ExUnit.Case, async: true

  alias Schooner.Eval.Error
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "define-syntax" do
    test "user-defined macro expands at top level" do
      assert run("""
             (define-syntax greet
               (syntax-rules ()
                 ((_ x) (cons 'hello x))))
             (greet 'world)
             """) == {:pair, Value.symbol("hello"), Value.symbol("world")}
    end

    test "redefining a macro replaces the previous transformer" do
      assert run("""
             (define-syntax m (syntax-rules () ((_ x) (* x 10))))
             (define-syntax m (syntax-rules () ((_ x) (+ x 100))))
             (m 7)
             """) == 107
    end

    test "no matching rule raises a Schooner.Eval.Error" do
      e =
        assert_raise Error, fn ->
          run("""
          (define-syntax bin (syntax-rules () ((_ a b) (cons a b))))
          (bin 1)
          """)
        end

      assert e.reason == {:bad_special_form, "bin"}
    end

    test "literals match by name only" do
      # `=>` and `else` are r7rs literals in `cond` / `case`; here we
      # define our own macro that uses `=>` as a literal to confirm
      # the matcher distinguishes literals from pattern variables.
      assert run("""
             (define-syntax arrow
               (syntax-rules (=>)
                 ((_ x => y) (list 'matched x y))
                 ((_ x y) (list 'not-matched x y))))
             (list (arrow 1 => 2) (arrow 1 2))
             """) ==
               Value.list([
                 Value.list([Value.symbol("matched"), 1, 2]),
                 Value.list([Value.symbol("not-matched"), 1, 2])
               ])
    end

    test "the macro's keyword identifier in head position is treated as a wildcard" do
      assert run("""
             (define-syntax foo
               (syntax-rules ()
                 ((foo x) (list 'kw x))))
             (foo 5)
             """) == Value.list([Value.symbol("kw"), 5])
    end
  end

  describe "ellipsis" do
    test "single-level ellipsis splices a list of values into a list template" do
      assert run("""
             (define-syntax mk-list
               (syntax-rules ()
                 ((_ x ...) (list x ...))))
             (mk-list 1 2 3 4)
             """) == Value.list([1, 2, 3, 4])
    end

    test "ellipsis with leading and trailing fixed elements" do
      assert run("""
             (define-syntax bracketed
               (syntax-rules ()
                 ((_ a middle ... z)
                  (list 'first a 'middles (list middle ...) 'last z))))
             (bracketed 10 20 30 40 50)
             """) ==
               Value.list([
                 Value.symbol("first"),
                 10,
                 Value.symbol("middles"),
                 Value.list([20, 30, 40]),
                 Value.symbol("last"),
                 50
               ])
    end

    test "nested ellipsis preserves the list-of-lists shape" do
      assert run("""
             (define-syntax pairs
               (syntax-rules ()
                 ((_ (a b) ...) (list (list a b) ...))))
             (pairs (1 2) (3 4) (5 6))
             """) ==
               Value.list([
                 Value.list([1, 2]),
                 Value.list([3, 4]),
                 Value.list([5, 6])
               ])
    end

    test "two pattern variables driven by the same ellipsis stay aligned" do
      assert run("""
             (define-syntax zipped
               (syntax-rules ()
                 ((_ (a b) ...) (list (cons a b) ...))))
             (zipped (1 'x) (2 'y) (3 'z))
             """) ==
               Value.list([
                 {:pair, 1, Value.symbol("x")},
                 {:pair, 2, Value.symbol("y")},
                 {:pair, 3, Value.symbol("z")}
               ])
    end

    test "ellipsis under a different parent ellipsis flattens correctly" do
      assert run("""
             (define-syntax flatten-2
               (syntax-rules ()
                 ((_ (x ...) ...) (list x ... ...))))
             (flatten-2 (1 2) (3 4 5) (6))
             """) == Value.list([1, 2, 3, 4, 5, 6])
    end
  end

  describe "hygiene" do
    test "template-introduced binder does not capture a user identifier" do
      # If `t` in the template were not alpha-renamed, the inner
      # `(let ((t e1)) ...)` would shadow the user's `t` and the test
      # would observe `#f` instead of `'oops`.
      assert run("""
             (define-syntax my-or
               (syntax-rules ()
                 ((_) #f)
                 ((_ e) e)
                 ((_ e1 e2 ...)
                  (let ((t e1)) (if t t (my-or e2 ...))))))
             (let ((t 'oops)) (my-or #f t))
             """) == Value.symbol("oops")
    end

    test "user identifier passed into a macro template is not bound by the macro's lambda" do
      assert run("""
             (define-syntax wrap
               (syntax-rules ()
                 ((_ e) (let ((y 99)) e))))
             (let ((y 7)) (wrap y))
             """) == 7
    end

    test "free template reference resolves to the runtime binding at use site" do
      assert run("""
             (define-syntax inc
               (syntax-rules ()
                 ((_ x) (+ x 1))))
             (inc 41)
             """) == 42
    end

    test "macro keyword can call itself recursively without losing meaning" do
      assert run("""
             (define-syntax sum
               (syntax-rules ()
                 ((_) 0)
                 ((_ x y ...) (+ x (sum y ...)))))
             (sum 1 2 3 4 5)
             """) == 15
    end
  end

  describe "let-syntax / letrec-syntax" do
    test "let-syntax binds a macro within its body and falls out of scope after" do
      assert run("""
             (let-syntax ((double (syntax-rules () ((_ x) (+ x x)))))
               (double 21))
             """) == 42

      assert_raise Error, fn ->
        run("""
        (let-syntax ((double (syntax-rules () ((_ x) (+ x x))))) (double 1))
        (double 2)
        """)
      end
    end

    test "letrec-syntax allows mutually recursive macros" do
      # A pair of macros that ping-pong over a syntactic list at
      # expansion time. Macros operate on syntax, not on values, so
      # the recursion has to bottom out on a structural pattern (the
      # empty list `()`) rather than a runtime computation. With
      # `let-syntax` only one would resolve; `letrec-syntax` makes
      # both visible in each other's templates.
      assert run("""
             (letrec-syntax
                 ((m1 (syntax-rules ()
                        ((_ ()) 'done-m1)
                        ((_ (x rest ...)) (m2 (rest ...)))))
                  (m2 (syntax-rules ()
                        ((_ ()) 'done-m2)
                        ((_ (x rest ...)) (m1 (rest ...))))))
               (m1 (a b c d)))
             """) == Value.symbol("done-m1")
    end

    test "let-syntax inner shadowing does not leak to outer use" do
      assert run("""
             (define-syntax m (syntax-rules () ((_ x) (* x 10))))
             (let-syntax ((m (syntax-rules () ((_ x) (+ x 100)))))
               (m 5))
             """) == 105

      assert run("""
             (define-syntax m (syntax-rules () ((_ x) (* x 10))))
             (let-syntax ((m (syntax-rules () ((_ x) (+ x 100)))))
               (m 5))
             (m 5)
             """) == 50
    end
  end

  describe "core-form interaction" do
    test "lambda parameters shadow an outer macro binding" do
      # If `m` were treated as a macro at the call site, the lambda
      # would expand `m` to `99`. Because lambda introduces a runtime
      # variable named `m`, the application within the body must
      # resolve to the parameter, not to the macro.
      assert run("""
             (define-syntax m (syntax-rules () ((_) 99)))
             ((lambda (m) (m)) (lambda () 'param))
             """) == Value.symbol("param")
    end

    test "quote bodies are not expanded" do
      # If the expander walked into quoted data, the user-written
      # `let` symbol would be expanded to the macro's body. Quotation
      # must short-circuit that walk.
      assert run("""
             '(let ((x 1)) x)
             """) ==
               Value.list([
                 Value.symbol("let"),
                 Value.list([Value.list([Value.symbol("x"), 1])]),
                 Value.symbol("x")
               ])
    end

    test "vector quasiquote with macro use inside an unquote still expands" do
      assert run("""
             (define-syntax inc (syntax-rules () ((_ x) (+ x 1))))
             `#(1 ,(inc 2) 3)
             """) == Value.vector([1, 3, 3])
    end
  end

  describe "torture: or as a user-defined macro" do
    test "shadows the bootstrap or and obeys short-circuit semantics" do
      # The `or` defined here has the same semantics as the bootstrap
      # `or`; what we are pinning is that it does not break under
      # capture-prone identifiers.
      assert run("""
             (define-syntax local-or
               (syntax-rules ()
                 ((_) #f)
                 ((_ e) e)
                 ((_ e1 e2 ...)
                  (let ((t e1)) (if t t (local-or e2 ...))))))
             (let ((t 'oops))
               (list (local-or #f #f t)
                     (local-or #f t)
                     (local-or t 'unused)))
             """) ==
               Value.list([Value.symbol("oops"), Value.symbol("oops"), Value.symbol("oops")])
    end
  end

  describe "torture: cond with =>" do
    test "expands and evaluates without re-evaluating the test expression" do
      # If the macro re-evaluated the test, the counter incremented
      # via the (lambda) hack here would record more than one tick.
      # We can't observe side effects without mutation, but we can
      # confirm the result with a function that *would* show
      # divergence if multiply applied.
      assert run("""
             (cond ((+ 1 2) => (lambda (x) (* x 10))))
             """) == 30
    end
  end

  describe "malformed special forms raise during expansion" do
    test "set! is rejected at expansion time" do
      e = assert_raise Error, fn -> run("(set! x 1)") end
      assert e.reason == {:bad_special_form, "set!"}
    end

    test "malformed lambda parameter list (non-symbol element)" do
      e = assert_raise Error, fn -> run("(lambda (x . 1) x)") end
      assert e.reason == {:bad_special_form, "lambda"}
    end

    test "malformed letrec*" do
      e = assert_raise Error, fn -> run("(letrec* ((x)) x)") end
      assert e.reason == {:bad_special_form, "letrec*"}

      e = assert_raise Error, fn -> run("(letrec* (x) x)") end
      assert e.reason == {:bad_special_form, "letrec*"}
    end

    test "malformed guard" do
      # No clause list at all.
      e = assert_raise Error, fn -> run("(guard 1 2)") end
      assert e.reason == {:bad_special_form, "guard"}

      # Bad clause shape (clauses not a proper list).
      e = assert_raise Error, fn -> run("(guard (e . 1) 2)") end
      assert e.reason == {:bad_special_form, "guard"}
    end

    test "malformed let-syntax / letrec-syntax bindings" do
      e = assert_raise Error, fn -> run("(let-syntax 1 'x)") end
      assert e.reason == {:bad_special_form, "let-syntax"}

      e = assert_raise Error, fn -> run("(letrec-syntax 1 'x)") end
      assert e.reason == {:bad_special_form, "letrec-syntax"}
    end

    test "malformed define-record-type forms" do
      e = assert_raise Error, fn -> run("(define-record-type 1 (mk x) p? (x g))") end
      assert e.reason == {:bad_special_form, "define-record-type"}

      # Bad constructor spec.
      e = assert_raise Error, fn -> run("(define-record-type pt 1 pt? (x x-of))") end
      assert e.reason == {:bad_special_form, "define-record-type"}

      # Bad field-spec list.
      e = assert_raise Error, fn -> run("(define-record-type pt (mk x) pt? 1)") end
      assert e.reason == {:bad_special_form, "define-record-type"}
    end
  end

  describe "internal definition interaction" do
    test "macro that expands to internal define inside a lambda body" do
      assert run("""
             (define-syntax def-fn
               (syntax-rules ()
                 ((_ name body) (define name (lambda () body)))))
             ((lambda ()
                (def-fn pi-ish 314)
                (pi-ish)))
             """) == 314
    end
  end
end

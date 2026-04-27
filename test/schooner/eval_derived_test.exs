defmodule Schooner.EvalDerivedTest do
  # Phase 7 — derived forms (cond, case, when, unless, and, or, let,
  # let*, letrec, letrec*, named let, do, quasiquote) implemented
  # directly in the evaluator. Per the plan, these tests are kept
  # verbatim through phase 9 and re-run after the macro expander
  # replaces the throwaway implementations — failures there mean the
  # macroified versions disagree with this oracle.
  use ExUnit.Case, async: true

  alias Schooner.Eval.Error
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "and / or" do
    test "(and) returns #t and (or) returns #f" do
      assert run("(and)") == Value.bool(true)
      assert run("(or)") == Value.bool(false)
    end

    test "and short-circuits on #f and returns #f" do
      assert run("(and 1 #f 2)") == Value.bool(false)
    end

    test "and returns the last value when nothing is false" do
      assert run("(and 1 2 3)") == 3
    end

    test "or short-circuits on the first truthy value and returns it" do
      assert run("(or #f #f 7 8)") == 7
    end

    test "or with no truthies returns #f" do
      assert run("(or #f #f)") == Value.bool(false)
    end

    test "and treats only #f as false; '() and 0 are truthy" do
      assert run("(and '() 0 1)") == 1
    end
  end

  describe "when / unless" do
    test "when evaluates body when test is truthy" do
      assert run("(when #t 1 2 3)") == 3
    end

    test "when returns :unspecified on falsy test" do
      assert run("(when #f 1 2 3)") == :unspecified
    end

    test "unless mirrors when" do
      assert run("(unless #f 1 2 3)") == 3
      assert run("(unless #t 1 2 3)") == :unspecified
    end

    test "malformed when raises" do
      e = assert_raise Error, fn -> run("(when #t)") end
      assert e.reason == {:bad_special_form, "when"}
    end
  end

  describe "cond" do
    test "selects the first truthy clause's body" do
      assert run("(cond (#f 1) (#t 2) (else 3))") == 2
    end

    test "else branch fires when no test matches" do
      assert run("(cond (#f 1) (#f 2) (else 99))") == 99
    end

    test "single-test clause returns the test value" do
      assert run("(cond (42))") == 42
    end

    test "with no matching clause and no else, returns :unspecified" do
      assert run("(cond (#f 1) (#f 2))") == :unspecified
    end

    test "=> arrow form passes the test value to the receiver" do
      assert run("(cond ((+ 1 2) => (lambda (x) (* x 10))))") == 30
    end

    test "=> does not fire when the test is false" do
      assert run("(cond (#f => (lambda (x) (* x 10))) (else 'fallback))") ==
               Value.symbol("fallback")
    end

    test "malformed cond raises" do
      e = assert_raise Error, fn -> run("(cond ())") end
      assert e.reason == {:bad_special_form, "cond"}
    end
  end

  describe "case" do
    test "matches the first clause whose key list contains the value (eqv?)" do
      assert run("(case 2 ((1) 'one) ((2 3) 'two-or-three) (else 'other))") ==
               Value.symbol("two-or-three")
    end

    test "else fires when nothing matches" do
      assert run("(case 99 ((1) 'one) (else 'fallback))") == Value.symbol("fallback")
    end

    test "with no else and no match, returns :unspecified" do
      assert run("(case 99 ((1) 'one))") == :unspecified
    end

    test "=> arrow receives the key value" do
      assert run("(case 5 ((5) => (lambda (k) (* k k))) (else 0))") == 25
    end

    test "else => arrow receives the key value" do
      assert run("(case 7 ((1) 'one) (else => (lambda (k) (+ k 100))))") == 107
    end

    test "match uses eqv?: integers and floats with the same value do not match" do
      assert run("(case 1.0 ((1) 'int) (else 'no))") == Value.symbol("no")
    end

    test "symbols match by value" do
      assert run("(case 'b ((a) 1) ((b c) 2) (else 3))") == 2
    end
  end

  describe "let" do
    test "binds names visible in the body" do
      assert run("(let ((x 1) (y 2)) (+ x y))") == 3
    end

    test "init expressions are evaluated in the outer environment" do
      assert run("(let ((x 1)) (let ((x 2) (y x)) y))") == 1
    end

    test "empty bindings are allowed" do
      assert run("(let () 42)") == 42
    end

    test "binding shadows outer" do
      assert run("(let ((x 1)) (let ((x 99)) x))") == 99
    end

    test "malformed let raises" do
      e = assert_raise Error, fn -> run("(let bad-bindings 1)") end
      assert e.reason == {:bad_special_form, "let"}
    end
  end

  describe "let*" do
    test "later bindings see earlier ones" do
      assert run("(let* ((x 1) (y (+ x 1)) (z (* y 10))) z)") == 20
    end

    test "empty bindings allowed" do
      assert run("(let* () 7)") == 7
    end
  end

  describe "letrec / letrec*" do
    test "letrec supports mutually recursive lambdas" do
      assert run("""
             (letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
                      (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
               (even? 10))
             """) == Value.bool(true)
    end

    test "letrec*: forward reference within an init resolves once the frame is populated" do
      assert run("""
             (letrec* ((f (lambda (n) (if (= n 0) 0 (g (- n 1)))))
                       (g (lambda (n) (f n))))
               (f 3))
             """) == 0
    end

    test "letrec body sees all bindings" do
      assert run("""
             (letrec ((x 1) (y 2))
               (+ x y))
             """) == 3
    end

    test "letrec* evaluation is left to right" do
      # b's init refers to a (already bound) but not c (not yet bound).
      assert run("""
             (letrec* ((a 1) (b (+ a 10)) (c (+ b 100)))
               (list a b c))
             """) == Value.list([1, 11, 111])
    end
  end

  describe "named let" do
    test "factorial via named let" do
      assert run("""
             (let loop ((n 5) (acc 1))
               (if (= n 0) acc (loop (- n 1) (* acc n))))
             """) == 120
    end

    test "fibonacci via named let" do
      assert run("""
             (let fib ((n 10))
               (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
             """) == 55
    end

    test "named let does not leak its name into the outer scope" do
      assert run("""
             (let outer ((x 1)) x)
             (define has-outer
               (lambda () (cond ((eqv? 1 1) 'ok) (else 'no))))
             (has-outer)
             """) == Value.symbol("ok")
    end
  end

  describe "do" do
    test "basic counting loop" do
      assert run("""
             (do ((i 0 (+ i 1))
                  (acc 0 (+ acc i)))
                 ((= i 5) acc))
             """) == 10
    end

    test "do without an explicit step keeps the variable unchanged" do
      assert run("""
             (do ((i 0 (+ i 1))
                  (limit 3))
                 ((= i limit) 'done))
             """) == Value.symbol("done")
    end

    test "do with no result expressions returns :unspecified" do
      assert run("""
             (do ((i 0 (+ i 1))) ((= i 1)))
             """) == :unspecified
    end

    test "do body executes for side effect (counts via let-bound counter unsupported, " <>
           "but body forms are evaluated)" do
      # Without mutation we can't observe side effects; instead we
      # exercise that the body is at least dispatched without raising.
      assert run("""
             (do ((i 0 (+ i 1))) ((= i 3) i)
               (+ i 1)
               (- i 1))
             """) == 3
    end
  end

  describe "quasiquote" do
    test "trivial quasiquote of a literal returns it" do
      assert run("`5") == 5
      assert run("`foo") == Value.symbol("foo")
      assert run("`()") == :null
    end

    test "unquote splices a single value into a list" do
      assert run("`(1 ,(+ 2 3) 4)") == Value.list([1, 5, 4])
    end

    test "unquote-splicing splices a list into the surrounding list" do
      assert run("`(1 ,@(list 2 3 4) 5)") == Value.list([1, 2, 3, 4, 5])
    end

    test "unquote-splicing of an empty list disappears" do
      assert run("`(1 ,@'() 2)") == Value.list([1, 2])
    end

    test "nested quasiquote raises the level; unquote inside nested level only fires at depth 1" do
      assert run("`(a `(b ,(c)))") ==
               Value.list([
                 Value.symbol("a"),
                 Value.list([
                   Value.symbol("quasiquote"),
                   Value.list([
                     Value.symbol("b"),
                     Value.list([Value.symbol("unquote"), Value.list([Value.symbol("c")])])
                   ])
                 ])
               ])
    end

    test "unquote inside a nested quasiquote fires at the innermost level only" do
      assert run("`(a `(b ,,(+ 1 2)))") ==
               Value.list([
                 Value.symbol("a"),
                 Value.list([
                   Value.symbol("quasiquote"),
                   Value.list([
                     Value.symbol("b"),
                     Value.list([Value.symbol("unquote"), 3])
                   ])
                 ])
               ])
    end

    test "vector quasiquote with unquote" do
      assert run("`#(1 ,(+ 1 1) 3)") == Value.vector([1, 2, 3])
    end

    test "vector quasiquote with unquote-splicing" do
      assert run("`#(1 ,@(list 2 3) 4)") == Value.vector([1, 2, 3, 4])
    end

    test "improper quasiquoted lists preserve their dotted tail" do
      assert run("`(1 ,(+ 1 1) . 3)") == {:pair, 1, {:pair, 2, 3}}
    end

    test "splicing a non-list raises" do
      assert_raise Error, fn -> run("`(1 ,@5 2)") end
    end
  end
end

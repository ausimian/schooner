defmodule Schooner.EvalInternalDefinesTest do
  # Phase 8 — internal `define`s splice into a `letrec*` at the head
  # of any body that allows internal definitions (lambda, let, let*,
  # letrec*, when, unless, cond clauses, case clauses, named let).
  #
  # These tests also pin two related behaviours: forward references
  # to a not-yet-evaluated `letrec*` init are a runtime error, and
  # `define` appearing after a non-definition expression in the same
  # body is a syntax error.
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Eval.Error
  alias Schooner.Value

  defp run(source), do: Schooner.run!(source)

  defp assert_no_slot_leak(fun) do
    before = count_rec_slots()
    fun.()
    assert count_rec_slots() == before
  end

  defp count_rec_slots do
    Process.get_keys()
    |> Enum.count(fn k ->
      is_reference(k) and match?({:rec_frame, _}, Process.get(k))
    end)
  end

  describe "internal defines in lambda body" do
    test "single internal define is visible in the body" do
      assert run("""
             ((lambda ()
                (define x 7)
                x))
             """) == 7
    end

    test "multiple internal defines accumulate left-to-right" do
      assert run("""
             ((lambda ()
                (define a 1)
                (define b (+ a 1))
                (define c (+ b 1))
                (list a b c)))
             """) == Value.list([1, 2, 3])
    end

    test "function-form internal define produces a callable closure" do
      assert run("""
             ((lambda (x)
                (define (double n) (* n 2))
                (double x))
              21)
             """) == 42
    end

    test "internal define shadows an outer binding only inside the lambda" do
      assert run("""
             (define x 'outer)
             ((lambda ()
                (define x 'inner)
                x))
             """) == Value.symbol("inner")

      assert run("""
             (define x 'outer)
             ((lambda ()
                (define x 'inner)
                x))
             x
             """) == Value.symbol("outer")
    end

    test "mutual recursion via internal defines (forward reference inside lambda)" do
      assert run("""
             ((lambda (n)
                (define (even? k) (if (= k 0) #t (odd? (- k 1))))
                (define (odd? k)  (if (= k 0) #f (even? (- k 1))))
                (even? n))
              10)
             """) == Value.bool(true)

      assert run("""
             ((lambda (n)
                (define (even? k) (if (= k 0) #t (odd? (- k 1))))
                (define (odd? k)  (if (= k 0) #f (even? (- k 1))))
                (even? n))
              7)
             """) == Value.bool(false)
    end
  end

  describe "internal defines in let bodies" do
    test "let body" do
      assert run("""
             (let ((x 10))
               (define y (+ x 5))
               (* x y))
             """) == 150
    end

    test "let* body" do
      assert run("""
             (let* ((x 1) (y 2))
               (define z (+ x y))
               (* z z))
             """) == 9
    end

    test "letrec* body" do
      assert run("""
             (letrec* ((a 1))
               (define b (+ a 10))
               (+ a b))
             """) == 12
    end

    test "named let body" do
      assert run("""
             (let outer ((n 3))
               (define double (lambda (x) (* x 2)))
               (double n))
             """) == 6
    end
  end

  describe "internal defines in cond / case / when / unless bodies" do
    test "cond clause body" do
      assert run("""
             (cond ((= 1 1)
                    (define x 100)
                    (+ x 1))
                   (else 0))
             """) == 101
    end

    test "cond else body" do
      assert run("""
             (cond ((= 1 0) 'no)
                   (else
                    (define x 7)
                    (* x x)))
             """) == 49
    end

    test "case clause body" do
      assert run("""
             (case 2
               ((1 2)
                (define x 10)
                (+ x 5))
               (else 0))
             """) == 15
    end

    test "when body" do
      assert run("""
             (when #t
               (define x 4)
               (* x x))
             """) == 16
    end

    test "unless body" do
      assert run("""
             (unless #f
               (define a 'hi)
               a)
             """) == Value.symbol("hi")
    end
  end

  describe "syntactic constraints" do
    test "define after a non-definition expression in the same body is an error" do
      e =
        assert_raise Error, fn ->
          run("""
          ((lambda ()
             (define x 1)
             x
             (define y 2)
             y))
          """)
        end

      assert e.reason == :define_after_expression
    end

    test "a body containing only defines is rejected at expansion time" do
      e =
        assert_raise Error, fn ->
          run("""
          ((lambda ()
             (define x 1)
             (define y 2)))
          """)
        end

      assert e.reason == :empty_body
    end

    test "malformed internal define raises" do
      e =
        assert_raise Error, fn ->
          run("""
          ((lambda ()
             (define)
             1))
          """)
        end

      assert e.reason == {:bad_special_form, "define"}
    end
  end

  describe "letrec* forward-reference semantics" do
    test "closure body may reference a binding declared later in the same frame" do
      assert run("""
             (letrec* ((f (lambda (n) (if (= n 0) 'done (g n))))
                       (g (lambda (n) (f (- n 1)))))
               (f 3))
             """) == Value.symbol("done")
    end

    test "a closure created by an init can reference a later binding when applied later" do
      assert run("""
             (letrec* ((f (lambda () later))
                       (later 42))
               (f))
             """) == 42
    end

    test "forward reference within an init expression itself is a runtime error" do
      e =
        assert_raise Error, fn ->
          run("""
          (letrec* ((x y)
                    (y 1))
            x)
          """)
        end

      assert e.reason == {:rec_uninitialised, "y"}
    end

    test "letrec* inits run left-to-right; earlier bindings are visible in later inits" do
      assert run("""
             (letrec* ((a 1) (b (+ a 10)) (c (+ b 100)))
               (list a b c))
             """) == Value.list([1, 11, 111])
    end
  end

  describe "rec-frame slot lifecycle" do
    test "letrec* releases its process-dictionary slot when the body returns" do
      assert_no_slot_leak(fn ->
        assert Schooner.run!("(letrec* ((x 1) (y 2)) (+ x y))") == 3
      end)
    end

    test "letrec* releases its slot even when the body raises" do
      assert_no_slot_leak(fn ->
        assert_raise Error, fn -> Schooner.run!("(letrec* ((x 1)) (undefined-name))") end
      end)
    end

    test "named let releases its slot when the body returns" do
      assert_no_slot_leak(fn ->
        assert Schooner.run!("""
               (let loop ((n 5) (acc 1))
                 (if (= n 0) acc (loop (- n 1) (* acc n))))
               """) == 120
      end)
    end

    test "many sequential letrec*s do not leak slots" do
      assert_no_slot_leak(fn ->
        for _ <- 1..50 do
          Schooner.run!("(letrec* ((x 1) (y 2)) (+ x y))")
        end
      end)
    end
  end

  describe "TCO across letrec* try/rescue" do
    test "internal-define-driven mutual recursion at depth" do
      env =
        Env.new()
        |> Env.define(
          "zero-int?",
          Value.primitive("zero-int?", 1, fn [n] -> Value.bool(n === 0) end)
        )
        |> Env.define("sub1", Value.primitive("sub1", 1, fn [n] -> n - 1 end))

      source = """
      ((lambda (n)
         (define (even? k) (if (zero-int? k) #t (odd? (sub1 k))))
         (define (odd? k)  (if (zero-int? k) #f (even? (sub1 k))))
         (even? n))
       100000)
      """

      assert Schooner.eval!(source, env) == Value.bool(true)
      {:total_heap_size, heap} = Process.info(self(), :total_heap_size)
      assert heap < 5_000_000
    end

    # Stress shape that exercises issue 25's TCO concern: every iteration
    # of the tail-recursive `loop` re-enters `eval_letrec_star` because
    # the body has an internal define. The walk-and-rewrite path holds
    # one `try/rescue` frame per call until the body returns. Stack must
    # stay constant — heap accumulates per-iteration allocations that GC
    # reclaims, so we bound stack_size rather than total_heap_size here.
    test "tail loop with internal define on every call preserves stack TCO" do
      env =
        Env.new()
        |> Env.define(
          "zero-int?",
          Value.primitive("zero-int?", 1, fn [n] -> Value.bool(n === 0) end)
        )
        |> Env.define("sub1", Value.primitive("sub1", 1, fn [n] -> n - 1 end))

      source = """
      (define (loop n)
        (define helper 1)
        (if (zero-int? n) 'done (loop (sub1 n))))
      (loop 100000)
      """

      assert Schooner.eval!(source, env) == Value.symbol("done")
      {:stack_size, stack} = Process.info(self(), :stack_size)
      # 100k frames stacked unoptimised would push tens of thousands of
      # words; a healthy TCO leaves stack_size in low triple digits.
      assert stack < 1_000, "stack_size grew to #{stack} words — TCO likely broken"
    end
  end

  describe "letrec body return-value escape (issue 25)" do
    test "closure escapes via top-level binding, then resolves rec names" do
      assert run("""
             (define escaped
               (letrec ((helper (lambda () 42))
                        (caller (lambda () (helper))))
                 caller))
             (escaped)
             """) == 42
    end

    # Escape keeps the rec slot alive on purpose: the snapshot lives
    # in the slot so escaped closures (and any closures they reach via
    # rec lookups, including mutually-recursive ones) can resolve rec
    # names. Leakage is therefore bounded to actual closure escapes,
    # not letrec-form count.
    test "closure escape leaves exactly one rec slot per escaping letrec" do
      before = count_rec_slots()

      Schooner.run!("""
      (define escaped
        (letrec ((helper (lambda () 42))
                 (caller (lambda () (helper))))
          caller))
      (escaped)
      """)

      assert count_rec_slots() == before + 1
    end

    test "many non-escaping letrecs do not leak; many escaping ones leak per escape" do
      before = count_rec_slots()

      for _ <- 1..50 do
        Schooner.run!("(letrec ((x 1)) x)")
      end

      assert count_rec_slots() == before, "non-escaping letrecs should not leak"

      base = count_rec_slots()

      for _ <- 1..50 do
        Schooner.run!("(letrec ((f (lambda () 1))) f)")
      end

      assert count_rec_slots() == base + 50, "each escaping letrec leaves one slot"
    end

    test "closure escape via cons; both car and cdr resolve" do
      assert run("""
             (define p
               (letrec ((x 7)
                        (f (lambda () x)))
                 (cons f x)))
             (cons ((car p)) (cdr p))
             """) == [7 | 7]
    end

    test "closure escape via vector" do
      assert run("""
             (define v
               (letrec ((const (lambda () 11))
                        (boxed (lambda () (const))))
                 (vector const boxed)))
             (cons ((vector-ref v 0)) ((vector-ref v 1)))
             """) == [11 | 11]
    end

    test "closure escape via list of closures" do
      assert run("""
             (define fs
               (letrec ((make (lambda (n) (lambda () (* n 2)))))
                 (list (make 1) (make 2) (make 3))))
             (map (lambda (f) (f)) fs)
             """) == [2, 4, 6]
    end

    test "closure escape via record" do
      assert run("""
             (define-record-type box (make-box value) box?
               (value box-value))
             (define b
               (letrec ((helper (lambda () 99))
                        (caller (lambda () (helper))))
                 (make-box caller)))
             ((box-value b))
             """) == 99
    end

    test "closure escape via multi-values consumed by call-with-values" do
      assert run("""
             (call-with-values
               (lambda ()
                 (letrec ((helper (lambda () 1))
                          (caller (lambda () (helper))))
                   (values caller helper)))
               (lambda (a b) (cons (a) (b))))
             """) == [1 | 1]
    end

    test "nested letrecs: outer body returns inner-letrec closure" do
      assert run("""
             (define f
               (letrec ((x 1))
                 (letrec ((g (lambda () x)))
                   g)))
             (f)
             """) == 1
    end

    test "mutually-recursive escape resolves both directions" do
      assert run("""
             (define ev
               (letrec ((my-even? (lambda (n) (if (= n 0) #t (my-odd? (- n 1)))))
                        (my-odd?  (lambda (n) (if (= n 0) #f (my-even? (- n 1))))))
                 my-even?))
             (cons (ev 4) (ev 5))
             """) == [true | false]
    end

    test "mutually-recursive escape works through pair-wrapped pair of closures" do
      assert run("""
             (define pair-of
               (letrec ((my-even? (lambda (n) (if (= n 0) #t (my-odd? (- n 1)))))
                        (my-odd?  (lambda (n) (if (= n 0) #f (my-even? (- n 1))))))
                 (cons my-even? my-odd?)))
             (cons ((car pair-of) 6) ((cdr pair-of) 7))
             """) == [true | true]
    end

    test "deeper mutually-recursive escape: triadic mutual recursion" do
      assert run("""
             (define f
               (letrec ((a (lambda (n) (if (= n 0) 'a (b (- n 1)))))
                        (b (lambda (n) (if (= n 0) 'b (c (- n 1)))))
                        (c (lambda (n) (if (= n 0) 'c (a (- n 1))))))
                 a))
             (list (f 0) (f 1) (f 2) (f 3))
             """) == [Value.symbol("a"), Value.symbol("b"), Value.symbol("c"), Value.symbol("a")]
    end
  end
end

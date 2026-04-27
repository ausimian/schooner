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

  defp run(source), do: Schooner.run(source)

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

      assert e.reason in [:empty_body, {:bad_special_form, "lambda"}]
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
      before_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()

      assert Schooner.run("(letrec* ((x 1) (y 2)) (+ x y))") == 3

      after_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()
      assert after_keys == before_keys
    end

    test "letrec* releases its slot even when the body raises" do
      before_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()

      assert_raise Error, fn -> Schooner.run("(letrec* ((x 1)) (undefined-name))") end

      after_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()
      assert after_keys == before_keys
    end

    test "named let releases its slot when the body returns" do
      before_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()

      assert Schooner.run("""
             (let loop ((n 5) (acc 1))
               (if (= n 0) acc (loop (- n 1) (* acc n))))
             """) == 120

      after_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()
      assert after_keys == before_keys
    end

    test "many sequential letrec*s do not leak slots" do
      before_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()

      env = Schooner.standard_env()

      for _ <- 1..50 do
        Schooner.eval("(letrec* ((x 1) (y 2)) (+ x y))", env)
      end

      after_keys = Process.get_keys() |> Enum.filter(&is_reference/1) |> length()
      assert after_keys == before_keys
    end
  end

  describe "TCO across letrec* try/after" do
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

      assert Schooner.eval(source, env) == Value.bool(true)
      {:total_heap_size, heap} = Process.info(self(), :total_heap_size)
      assert heap < 5_000_000
    end
  end
end

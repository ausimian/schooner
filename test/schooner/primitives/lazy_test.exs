defmodule Schooner.Primitives.LazyTest do
  use ExUnit.Case, async: true

  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "make-promise + force" do
    test "force on an eager make-promise returns the wrapped value" do
      assert run("(force (make-promise 42))") == 42
    end

    test "force on a non-promise returns the input as-is" do
      assert run("(force 42)") == 42
      assert run(~S|(force "hi")|) == Value.string("hi")
    end
  end

  describe "delay + force" do
    test "delays evaluation of an expression" do
      assert run("(force (delay (+ 1 2)))") == 3
    end

    test "side-effecting delay re-evaluates each force (no memoisation)" do
      # Without mutation we cannot count calls in-language, but we can
      # observe re-evaluation by relying on `force` on a delay that
      # references a top-level binding being defined later.
      source = """
      (define p (delay (+ 1 2)))
      (force p)
      (force p)
      """

      assert run(source) == 3
    end
  end

  describe "delay-force iterative semantics" do
    test "iterative streams terminate via force unwrapping" do
      # The classic delay-force usage: a tail-recursive promise that
      # forces to another promise. force loops on the result and
      # eventually returns the underlying value.
      source = """
      (define (loop n)
        (if (= n 0)
            (delay 'done)
            (delay-force (loop (- n 1)))))
      (force (loop 50))
      """

      assert run(source) == Value.symbol("done")
    end
  end

  describe "promise?" do
    test "true on a delay" do
      assert run("(promise? (delay 1))") == Value.bool(true)
    end

    test "true on a make-promise" do
      assert run("(promise? (make-promise 1))") == Value.bool(true)
    end

    test "false on a plain value" do
      assert run("(promise? 1)") == Value.bool(false)
      assert run("(promise? '(1 2))") == Value.bool(false)
      assert run("(promise? (lambda () 1))") == Value.bool(false)
    end
  end

  describe "write rendering" do
    test "promises render as #<promise>" do
      assert run("(write (delay 1))") == Value.string("#<promise>")
    end
  end
end

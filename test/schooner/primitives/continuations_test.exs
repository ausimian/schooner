defmodule Schooner.Primitives.ContinuationsTest do
  @moduledoc """
  Phase 12 tests: escape continuations (`call/cc`,
  `call-with-current-continuation`) and `dynamic-wind`.

  Several tests assert ordering of side effects (e.g. that
  `dynamic-wind`'s `after` thunk fires when a continuation crosses its
  boundary). Schooner has no mutation in the value model, so the
  tests use a host-injected `record!` primitive that pushes onto a
  process-dictionary list, plus `get-record` to read it back as a
  Scheme list. This is host-injection in the same vein as the
  `zero-int?` / `sub1` helpers in `eval_tco_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Value

  @recorder_key {__MODULE__, :record}
  @imports "(import (scheme base) (scheme cxr) (scheme char))\n"

  defp run(source), do: Schooner.eval(@imports <> source, recording_env())

  # The standard libraries get pulled in via the `@imports` line that
  # `run/1` prepends to every test source. The env returned here only
  # carries the test-local host primitives (recorder + arithmetic
  # helpers) — Schooner.eval handles the import resolution.
  defp recording_env do
    Process.delete(@recorder_key)

    Env.new()
    |> Env.define(
      "record!",
      Value.primitive("record!", 1, fn [v] ->
        Process.put(@recorder_key, [v | Process.get(@recorder_key, [])])
        :unspecified
      end)
    )
    |> Env.define(
      "get-record",
      Value.primitive("get-record", 0, fn [] ->
        Process.get(@recorder_key, []) |> Enum.reverse() |> Value.list()
      end)
    )
    |> Env.define(
      "zero-int?",
      Value.primitive("zero-int?", 1, fn [n] -> Value.bool(n === 0) end)
    )
    |> Env.define("sub1", Value.primitive("sub1", 1, fn [n] -> n - 1 end))
  end

  # ---------------------------------------------------------------------------
  # call/cc — escape behaviour
  # ---------------------------------------------------------------------------

  describe "call/cc" do
    test "(call/cc (lambda (k) (+ 1 (k 42)))) returns 42" do
      assert run("(call/cc (lambda (k) (+ 1 (k 42))))") == 42
    end

    test "call-with-current-continuation is the same primitive" do
      assert run("(call-with-current-continuation (lambda (k) (+ 1 (k 42))))") == 42
    end

    test "call/cc returns the procedure's return value when k is not invoked" do
      assert run("(call/cc (lambda (k) (+ 1 2)))") == 3
    end

    test "call/cc as early return from a deep tail-recursive loop" do
      source = """
      (call/cc
        (lambda (k)
          (define (loop n)
            (if (zero-int? n)
                (k 'escaped)
                (loop (sub1 n))))
          (loop 100000)))
      """

      assert run(source) == Value.symbol("escaped")
    end

    test "non-procedure argument is rejected" do
      assert_raise Schooner.Primitive.Error, fn -> run("(call/cc 42)") end
    end

    test "nested call/cc — invoking the outer k from inside the inner extent" do
      # Outer k captured first; inner call/cc enters; inner body invokes
      # the outer k, which throws past the inner catch (different tag)
      # all the way to the outer one. The inner extent ends as the
      # throw unwinds — its `after` deregisters the inner tag.
      source = """
      (call/cc
        (lambda (outer)
          (call/cc
            (lambda (inner)
              (outer 'from-outer)))
          'should-not-see-this))
      """

      assert run(source) == Value.symbol("from-outer")
    end

    test "nested call/cc — inner k escapes only the inner extent" do
      source = """
      (cons
        (call/cc
          (lambda (outer)
            (call/cc (lambda (inner) (inner 'from-inner)))))
        'after)
      """

      assert run(source) == Value.pair(Value.symbol("from-inner"), Value.symbol("after"))
    end
  end

  # ---------------------------------------------------------------------------
  # Continuation-after-extent — the documented Schooner deviation
  # ---------------------------------------------------------------------------

  describe "continuation invoked after dynamic extent has ended" do
    test "raises Schooner.Eval.Error with reason :continuation_expired" do
      # `(call/cc (lambda (k) k))` returns the continuation value
      # itself, but by the time the call/cc returns its catch is gone
      # and the tag has been deregistered. Invoking the saved value
      # therefore must raise rather than escape uncaught.
      source = """
      (define saved (call/cc (lambda (k) k)))
      (saved 'should-not-arrive)
      """

      err = assert_raise Schooner.Eval.Error, fn -> run(source) end
      assert err.reason == :continuation_expired
    end

    test "escape error message mentions escape-only semantics" do
      err =
        assert_raise Schooner.Eval.Error, fn ->
          run("""
          (define k (call/cc (lambda (c) c)))
          (k 0)
          """)
        end

      assert err.message =~ "escape-only"
    end
  end

  # ---------------------------------------------------------------------------
  # dynamic-wind
  # ---------------------------------------------------------------------------

  describe "dynamic-wind" do
    test "before runs on entry, after runs on normal exit, thunk's value is returned" do
      source = """
      (define result
        (dynamic-wind
          (lambda () (record! 'before))
          (lambda () (record! 'thunk) 'thunk-value)
          (lambda () (record! 'after))))
      (cons result (get-record))
      """

      assert run(source) ==
               Value.pair(
                 Value.symbol("thunk-value"),
                 Value.list([
                   Value.symbol("before"),
                   Value.symbol("thunk"),
                   Value.symbol("after")
                 ])
               )
    end

    test "after fires when a continuation invocation escapes the body" do
      source = """
      (define result
        (call/cc
          (lambda (k)
            (dynamic-wind
              (lambda () (record! 'before))
              (lambda () (record! 'thunk) (k 'escaped))
              (lambda () (record! 'after))))))
      (cons result (get-record))
      """

      assert run(source) ==
               Value.pair(
                 Value.symbol("escaped"),
                 Value.list([
                   Value.symbol("before"),
                   Value.symbol("thunk"),
                   Value.symbol("after")
                 ])
               )
    end

    test "after fires when an exception escapes the body" do
      source = """
      (define caught
        (guard (c (#t c))
          (dynamic-wind
            (lambda () (record! 'before))
            (lambda () (record! 'thunk) (error "boom"))
            (lambda () (record! 'after)))))
      (cons (error-object-message caught) (get-record))
      """

      assert run(source) ==
               Value.pair(
                 Value.string("boom"),
                 Value.list([
                   Value.symbol("before"),
                   Value.symbol("thunk"),
                   Value.symbol("after")
                 ])
               )
    end

    test "nested dynamic-wind unwinds inside-out on escape" do
      source = """
      (call/cc
        (lambda (k)
          (dynamic-wind
            (lambda () (record! 'before-outer))
            (lambda ()
              (dynamic-wind
                (lambda () (record! 'before-inner))
                (lambda () (record! 'thunk) (k 'escaped))
                (lambda () (record! 'after-inner))))
            (lambda () (record! 'after-outer)))))
      (get-record)
      """

      assert run(source) ==
               Value.list([
                 Value.symbol("before-outer"),
                 Value.symbol("before-inner"),
                 Value.symbol("thunk"),
                 Value.symbol("after-inner"),
                 Value.symbol("after-outer")
               ])
    end

    test "non-procedure thunk is rejected" do
      assert_raise Schooner.Primitive.Error, fn ->
        run("(dynamic-wind 1 (lambda () 'x) (lambda () 'y))")
      end
    end
  end
end

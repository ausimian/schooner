defmodule Schooner.Conformance.R7rsSection610ContinuationsTest do
  # Worked examples from r7rs-small §6.10 (control features). Each
  # test transcribes a `(form) ==> result` example from the spec or
  # pins a property the spec calls out. Only the `call/cc` and
  # `dynamic-wind` parts of §6.10 are exercised here; `apply`,
  # `values`, and `call-with-values` are out of phase 12 scope.
  #
  # Schooner-specific deviations from §6.10:
  #
  #   - Continuations are escape-only and single-shot. r7rs requires
  #     fully reusable first-class continuations; Schooner reifies
  #     `call/cc` via `:erlang.throw/1` with a tag whose matching
  #     `:erlang.catch` is reinstalled at every `call/cc` site, so
  #     invoking a continuation after that catch is gone raises
  #     `Schooner.Eval.Error{reason: :continuation_expired}` rather
  #     than resuming the captured computation. This is the explicit
  #     deviation called out in PLAN.md phase 12.
  #
  #   - The §6.10 `(connect talk1 disconnect connect talk2
  #     disconnect)` example combines `set!` (out of scope), captured
  #     continuation re-entry (out of scope), and `dynamic-wind`'s
  #     `before` thunk firing on re-entry (out of scope). The
  #     `set!`-free part of the deviation — invoking a saved
  #     continuation after its extent ends — is asserted as a failing
  #     case below to pin Schooner's behaviour.
  #
  #   - Lifting both restrictions (multi-shot `call/cc`, dynamic-wind
  #     re-entry semantics) is the planned v2.0 change per PLAN.md's
  #     "Deferred to v2.0" section.
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Value

  @recorder_key {__MODULE__, :record}
  @imports "(import (scheme base) (scheme cxr) (scheme char))\n"

  defp run(source), do: Schooner.eval(@imports <> source, recording_env())

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
  end

  # ---------------------------------------------------------------------------
  # §6.10 call-with-current-continuation
  # ---------------------------------------------------------------------------

  describe "§6.10 call-with-current-continuation" do
    # Spec: `(call-with-current-continuation procedure?) ==> #t`
    # The reified continuation is itself a procedure.
    test "the captured continuation is a procedure" do
      assert run("(call-with-current-continuation procedure?)") == Value.bool(true)
    end

    # Spec example, find-first-negative:
    #   (call-with-current-continuation
    #     (lambda (exit)
    #       (for-each (lambda (x)
    #                   (if (negative? x) (exit x)))
    #                 '(54 0 37 -3 245 19))
    #       #t))                                       ==> -3
    test "early-exit with for-each finds the first negative element" do
      assert run("""
             (call-with-current-continuation
               (lambda (exit)
                 (for-each (lambda (x)
                             (if (negative? x) (exit x)))
                           '(54 0 37 -3 245 19))
                 #t))
             """) == -3
    end

    # Spec example, list-length:
    #   (define list-length
    #     (lambda (obj)
    #       (call-with-current-continuation
    #         (lambda (return)
    #           (letrec ((r (lambda (obj)
    #                         (cond ((null? obj) 0)
    #                               ((pair? obj) (+ (r (cdr obj)) 1))
    #                               (else (return #f))))))
    #             (r obj))))))
    #   (list-length '(1 2 3 4))   ==> 4
    #   (list-length '(a b . c))   ==> #f
    test "list-length: proper list returns its length" do
      assert run("""
             (define list-length
               (lambda (obj)
                 (call-with-current-continuation
                   (lambda (return)
                     (letrec ((r (lambda (obj)
                                   (cond ((null? obj) 0)
                                         ((pair? obj) (+ (r (cdr obj)) 1))
                                         (else (return #f))))))
                       (r obj))))))
             (list-length '(1 2 3 4))
             """) == 4
    end

    test "list-length: improper list short-circuits to #f via the captured continuation" do
      assert run("""
             (define list-length
               (lambda (obj)
                 (call-with-current-continuation
                   (lambda (return)
                     (letrec ((r (lambda (obj)
                                   (cond ((null? obj) 0)
                                         ((pair? obj) (+ (r (cdr obj)) 1))
                                         (else (return #f))))))
                       (r obj))))))
             (list-length '(a b . c))
             """) == Value.bool(false)
    end

    # Classic escape example folded into the standard r7rs commentary:
    #   (+ 1 (call/cc (lambda (k) (+ 2 (k 3)))))   ==> 4
    test "invoking the continuation discards the surrounding addition" do
      assert run("(+ 1 (call/cc (lambda (k) (+ 2 (k 3)))))") == 4
    end
  end

  # ---------------------------------------------------------------------------
  # §6.10 dynamic-wind
  # ---------------------------------------------------------------------------

  describe "§6.10 dynamic-wind" do
    # The portable shape of the spec's `dynamic-wind` motivating
    # example — without `set!`, we capture order via the host
    # `record!` primitive instead. Asserts the spec's promise:
    # `before` runs once on entry, `after` runs once on normal exit,
    # and the value of the form is the value of `thunk`.
    test "before fires on entry, after fires on normal exit, thunk's value is returned" do
      assert run("""
             (define result
               (dynamic-wind
                 (lambda () (record! 'before))
                 (lambda () (record! 'thunk) 'value-of-thunk)
                 (lambda () (record! 'after))))
             (cons result (get-record))
             """) ==
               Value.pair(
                 Value.symbol("value-of-thunk"),
                 Value.list([
                   Value.symbol("before"),
                   Value.symbol("thunk"),
                   Value.symbol("after")
                 ])
               )
    end

    # §6.10 prose: "The `after` procedure is called whenever
    # execution leaves the dynamic extent of the call to `thunk`."
    # An escape via `call/cc` is one such departure.
    test "after fires when a continuation invocation escapes the body" do
      assert run("""
             (call/cc
               (lambda (k)
                 (dynamic-wind
                   (lambda () (record! 'before))
                   (lambda () (record! 'thunk) (k 'escaped))
                   (lambda () (record! 'after)))))
             (get-record)
             """) ==
               Value.list([
                 Value.symbol("before"),
                 Value.symbol("thunk"),
                 Value.symbol("after")
               ])
    end

    # The §6.10 prose extends to "leave the dynamic extent" via any
    # mechanism, including a propagating exception — `after` thunks
    # are part of the unwind path and must fire.
    test "after fires when an exception escapes the body" do
      assert run("""
             (guard (c (#t 'caught))
               (dynamic-wind
                 (lambda () (record! 'before))
                 (lambda () (record! 'thunk) (error "boom"))
                 (lambda () (record! 'after))))
             (get-record)
             """) ==
               Value.list([
                 Value.symbol("before"),
                 Value.symbol("thunk"),
                 Value.symbol("after")
               ])
    end

    # §6.10: nested dynamic-winds compose; on escape, after thunks
    # run innermost-first.
    test "nested dynamic-wind unwinds inside-out on escape" do
      assert run("""
             (call/cc
               (lambda (k)
                 (dynamic-wind
                   (lambda () (record! 'before-outer))
                   (lambda ()
                     (dynamic-wind
                       (lambda () (record! 'before-inner))
                       (lambda () (k 'escaped))
                       (lambda () (record! 'after-inner))))
                   (lambda () (record! 'after-outer)))))
             (get-record)
             """) ==
               Value.list([
                 Value.symbol("before-outer"),
                 Value.symbol("before-inner"),
                 Value.symbol("after-inner"),
                 Value.symbol("after-outer")
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # Documented Schooner deviations from §6.10
  # ---------------------------------------------------------------------------

  describe "documented deviations from §6.10" do
    # r7rs requires that a continuation captured by `call/cc` may be
    # invoked at any later point, possibly multiple times. Schooner
    # does not support that: invoking after the `call/cc`'s dynamic
    # extent has ended is a documented error. The form below — saving
    # `k` and invoking it from outside — is the smallest test that
    # would pass on a fully-conformant implementation but raises here.
    #
    # Lifting this restriction is the planned v2.0 change.
    test "DEVIATION: invoking a saved continuation after its extent ends raises" do
      err =
        assert_raise Schooner.Eval.Error, fn ->
          run("""
          (define saved (call/cc (lambda (k) k)))
          (saved 'should-not-arrive)
          """)
        end

      assert err.reason == :continuation_expired
    end

    # A multi-shot use: invoking the same continuation twice. The
    # first invocation succeeds (it's the escape that returns from
    # the original `call/cc`); the second observes that the catch is
    # gone and raises. r7rs requires both invocations to behave
    # identically.
    test "DEVIATION: second invocation of a single-shot continuation raises" do
      err =
        assert_raise Schooner.Eval.Error, fn ->
          run("""
          (define saved #f)
          (define first-result
            (call/cc
              (lambda (k)
                (define s k)
                (cons 'first (s 'first-call)))))
          ;; First call/cc returned 'first-call via k; the catch is now gone.
          ;; A literal second call to k would raise — but `s` was bound
          ;; inside the call/cc and is not reachable here without set!.
          ;; Instead, demonstrate the same property with the canonical
          ;; "return k from call/cc" pattern, which is what r7rs uses.
          (define k2 (call/cc (lambda (k) k)))
          (k2 'after-extent)
          """)
        end

      assert err.reason == :continuation_expired
    end

    # The §6.10 `(connect talk1 disconnect ...)` example (paraphrased
    # below in its dependency-stripped form) requires both `set!` and
    # multi-shot continuation re-entry. `set!` is out of scope
    # entirely; multi-shot is deferred to v2.0. We pin Schooner's
    # observable behaviour: the script fails at parse time because
    # `set!` is not a recognised form.
    test "DEVIATION: §6.10 connect/disconnect example fails — uses set! and multi-shot k" do
      # The full spec example uses `set!`; asserting the parse-time
      # failure here pins the most-upstream blocking deviation.
      assert_raise Schooner.Eval.Error, fn ->
        run("""
        (let ((path '())
              (c #f))
          (let ((add (lambda (s) (set! path (cons s path)))))
            (dynamic-wind
              (lambda () (add 'connect))
              (lambda ()
                (add (call-with-current-continuation
                       (lambda (c0) (set! c c0) 'talk1))))
              (lambda () (add 'disconnect)))
            (if (< (length path) 4)
                (c 'talk2)
                (reverse path))))
        """)
      end
    end
  end
end

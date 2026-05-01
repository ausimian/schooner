defmodule Schooner.Conformance.R7rsSection611ExceptionsTest do
  # Worked examples from r7rs-small §6.11 (exceptions). Each test
  # transcribes a `(form) ==> result` example from the spec or pins
  # a property the spec calls out as required of an exception
  # system.
  #
  # Schooner-specific deviations from §6.11:
  #
  #   - `with-exception-handler` and `guard` rely on Elixir
  #     `throw`/`catch` rather than `call/cc` for the escape; from
  #     the user's perspective the observable behaviour matches the
  #     spec (escape-only continuations are sufficient for both).
  #     Multi-shot `call/cc` is not supported (phase 12 caveat) and
  #     no example here exercises it.
  #   - A handler installed by `with-exception-handler` that
  #     returns from a non-continuable `raise` triggers a secondary
  #     error object whose message is implementation-defined; we
  #     pin Schooner's wording in the unit suite, not here.
  #   - `read-error?` and `file-error?` always return `#f` for
  #     user-constructed error objects: Schooner has no port-based
  #     reader and no file I/O (out-of-scope per the PLAN), so no
  #     primitive currently raises with those kinds.
  use ExUnit.Case, async: true

  alias Schooner.Value

  defp run(source), do: Schooner.run!(source)

  # ---------------------------------------------------------------------------
  # §6.11 with-exception-handler
  # ---------------------------------------------------------------------------

  describe "§6.11 with-exception-handler / raise" do
    test "spec example: raise inside with-exception-handler reaches the handler" do
      # Spec example, adapted for Schooner (no display/newline; we
      # collect the handler's observation into a list instead):
      #
      #   (with-exception-handler
      #     (lambda (condition)
      #       (cond ((string? condition)
      #              (display condition))
      #             (else
      #              (display "a warning has been issued")))
      #       42)
      #     (lambda ()
      #       (+ (raise-continuable "should be a number") 23)))
      #         ==> a warning has been issued <or> the string itself, then 65
      assert run(~S|
               (with-exception-handler
                 (lambda (condition)
                   (cond ((string? condition) condition)
                         (else 'warning))
                   42)
                 (lambda ()
                   (+ (raise-continuable "should be a number") 23)))|) == 65
    end

    test "raise (non-continuable): handler return triggers secondary error" do
      # Spec §6.11: "If the handler returns when called by raise,
      # a secondary error is raised in the same dynamic environment
      # as the handler." Schooner surfaces that secondary error as
      # an error object whose only irritant is the original value.
      assert run(~S|
               (guard (c ((error-object? c)
                          (car (error-object-irritants c))))
                 (with-exception-handler
                   (lambda (c) 'returned)
                   (lambda () (raise 'orig))))|) == Value.symbol("orig")
    end
  end

  # ---------------------------------------------------------------------------
  # §6.11 raise-continuable
  # ---------------------------------------------------------------------------

  describe "§6.11 raise-continuable" do
    test "handler return value is the value of (raise-continuable obj)" do
      assert run(~S|
               (with-exception-handler
                 (lambda (c) (* c 2))
                 (lambda () (+ 1 (raise-continuable 5))))|) == 11
    end

    test "handler stack is restored after a continuable raise returns" do
      # Two consecutive raises in the same dynamic extent must hit
      # the same handler — the handler's dynamic extent is the
      # whole `with-exception-handler` body, not just the first
      # raise.
      assert run(~S|
               (with-exception-handler
                 (lambda (c) (* c 10))
                 (lambda ()
                   (+ (raise-continuable 1)
                      (raise-continuable 2))))|) == 30
    end
  end

  # ---------------------------------------------------------------------------
  # §6.11 error / error-object accessors
  # ---------------------------------------------------------------------------

  describe "§6.11 error and accessors" do
    test "spec example: (error \"...\" ...) raises a non-continuable error object" do
      # (error "Not a list:" 'a) ==> a non-continuable error
      assert run(~S|
               (guard (c ((error-object? c)
                          (list (error-object-message c)
                                (error-object-irritants c))))
                 (error "Not a list:" 'a))|) ==
               Value.list([
                 Value.string("Not a list:"),
                 Value.list([Value.symbol("a")])
               ])
    end

    test "error-object-message returns the original message" do
      assert run(~S|
               (guard (c (#t (error-object-message c)))
                 (error "boom"))|) == Value.string("boom")
    end

    test "error-object-irritants returns the original list" do
      assert run(~S|
               (guard (c (#t (error-object-irritants c)))
                 (error "boom" 1 'two "three"))|) ==
               Value.list([1, Value.symbol("two"), Value.string("three")])
    end

    test "error-object? on non-errors returns #f" do
      assert run("(error-object? 'x)") == Value.bool(false)
      assert run(~S|(error-object? "string")|) == Value.bool(false)
      assert run("(error-object? '())") == Value.bool(false)
      assert run("(error-object? 42)") == Value.bool(false)
    end

    test "read-error? / file-error? are #f for user-created error objects" do
      assert run(~S|
               (guard (c (#t (list (error-object? c) (read-error? c) (file-error? c))))
                 (error "boom"))|) ==
               Value.list([Value.bool(true), Value.bool(false), Value.bool(false)])
    end
  end

  # ---------------------------------------------------------------------------
  # §6.11 guard
  # ---------------------------------------------------------------------------

  describe "§6.11 guard" do
    test "spec example: guard with a matching clause yields that clause's value" do
      # (guard (condition
      #          ((assq 'a condition) => cdr)
      #          ((assq 'b condition)))
      #   (raise (list (cons 'a 42))))
      #     ==> 42
      assert run(~S|
               (guard (condition
                        ((assq 'a condition) => cdr)
                        ((assq 'b condition)))
                 (raise (list (cons 'a 42))))|) == 42
    end

    test "spec example: guard returns the matching pair when => is absent" do
      # (guard (condition
      #          ((assq 'a condition) => cdr)
      #          ((assq 'b condition)))
      #   (raise (list (cons 'b 23))))
      #     ==> (b . 23)
      assert run(~S|
               (guard (condition
                        ((assq 'a condition) => cdr)
                        ((assq 'b condition)))
                 (raise (list (cons 'b 23))))|) == Value.pair(Value.symbol("b"), 23)
    end

    test "no clause matches: condition is re-raised in the surrounding handler" do
      assert run(~S|
               (guard (outer (#t (cons 'outer outer)))
                 (guard (inner ((number? inner) 'inner-num))
                   (raise 'sym)))|) == Value.pair(Value.symbol("outer"), Value.symbol("sym"))
    end

    test "else clause is the final catch-all" do
      assert run(~S|
               (guard (c ((number? c) 'num)
                         (else 'fallback))
                 (raise 'not-a-number))|) == Value.symbol("fallback")
    end

    test "guard body returning normally yields its value (no clauses fire)" do
      assert run("(guard (c (#t 'never)) 1 2 3)") == 3
    end
  end

  # ---------------------------------------------------------------------------
  # §6.11 raised values that are not error objects
  # ---------------------------------------------------------------------------

  describe "§6.11 arbitrary raised values" do
    test "raise accepts any value, not just error objects" do
      assert run(~S|(guard (c (#t c)) (raise 42))|) == 42

      assert run(~S|(guard (c (#t c)) (raise '(a b c)))|) ==
               Value.list([Value.symbol("a"), Value.symbol("b"), Value.symbol("c")])

      assert run(~S|(guard (c (#t c)) (raise "string-condition"))|) ==
               Value.string("string-condition")
    end

    test "error-object? distinguishes error objects from other raised values" do
      assert run(~S|
               (guard (c (#t (error-object? c)))
                 (raise 42))|) == Value.bool(false)

      assert run(~S|
               (guard (c (#t (error-object? c)))
                 (error "boom"))|) == Value.bool(true)
    end
  end
end

defmodule Schooner.Primitives.ExceptionsTest do
  use ExUnit.Case, async: true

  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "error object construction" do
    test "(error msg) constructs and raises an error object" do
      e =
        assert_raise Schooner.Error, fn ->
          run(~S|(error "boom")|)
        end

      assert {:error_obj, :user, "boom", []} = e.value
    end

    test "(error msg irritant ...) carries irritants" do
      e =
        assert_raise Schooner.Error, fn ->
          run(~S|(error "boom" 1 'two)|)
        end

      assert {:error_obj, :user, "boom", [1, {:sym, "two"}]} = e.value
      assert Schooner.Error.irritants(e) == [1, {:sym, "two"}]
    end

    test "non-string message rejected" do
      assert_raise Schooner.Primitive.Error, fn -> run("(error 42)") end
    end
  end

  describe "predicates" do
    test "error-object? distinguishes error objects from other values" do
      assert run(~S|(error-object? (guard (c (#t c)) (error "x")))|) == Value.bool(true)
      assert run("(error-object? 'x)") == Value.bool(false)
      assert run(~S|(error-object? "x")|) == Value.bool(false)
      assert run("(error-object? '())") == Value.bool(false)
    end

    test "error? is the same predicate" do
      assert run(~S|(error? (guard (c (#t c)) (error "x")))|) == Value.bool(true)
      assert run("(error? 0)") == Value.bool(false)
    end

    test "read-error? / file-error? are false for user-created errors" do
      assert run(~S|(read-error? (guard (c (#t c)) (error "x")))|) == Value.bool(false)
      assert run(~S|(file-error? (guard (c (#t c)) (error "x")))|) == Value.bool(false)
    end
  end

  describe "error-object-message / error-object-irritants" do
    test "accessors return the original message and irritants" do
      assert run(~S|
               (define e (guard (c (#t c)) (error "msg" 1 2 3)))
               (error-object-message e)|) == Value.string("msg")

      assert run(~S|
               (define e (guard (c (#t c)) (error "msg" 1 2 3)))
               (error-object-irritants e)|) == Value.list([1, 2, 3])
    end

    test "non-error-object input raises a structured error" do
      assert_raise Schooner.Primitive.Error, fn ->
        run("(error-object-message 5)")
      end
    end
  end

  describe "raise" do
    test "raise inside guard delivers the raised value to the handler" do
      assert run(~S|(guard (c (#t c)) (raise 'oops))|) == Value.symbol("oops")
    end

    test "raise inside with-exception-handler invokes the handler" do
      # The user-supplied handler is wrapped to call `error` so the
      # outer guard sees a deterministic value — proves the handler
      # ran and observed the raised value, since the alternative
      # (handler not invoked) would propagate `(raise 'orig)` directly.
      assert run(~S|
               (guard (c ((error-object? c)
                          (car (error-object-irritants c))))
                 (with-exception-handler
                   (lambda (c) (error "handler-saw" c))
                   (lambda () (raise 'orig))))|) == Value.symbol("orig")
    end

    test "non-continuable raise returns secondary error to outer handler" do
      # Inner with-exception-handler's handler returns normally, so a
      # secondary error object with the original raised value as its
      # irritant is raised in the outer dynamic extent.
      assert run(~S|
               (guard (c ((error-object? c)
                          (cons (error-object-message c)
                                (error-object-irritants c))))
                 (with-exception-handler
                   (lambda (c) 'handler-returned)
                   (lambda () (raise 'orig))))|) ==
               Value.pair(
                 Value.string("exception handler returned from a non-continuable raise"),
                 Value.list([Value.symbol("orig")])
               )
    end

    test "unhandled raise propagates to the host as Schooner.Error" do
      e =
        assert_raise Schooner.Error, fn ->
          run("(raise 'boom)")
        end

      assert e.value == Value.symbol("boom")
    end

    test "unhandled error object propagates with irritants attached" do
      e =
        assert_raise Schooner.Error, fn ->
          run(~S|(error "message" 1 2)|)
        end

      assert Schooner.Error.irritants(e) == [1, 2]
      assert {:error_obj, :user, "message", _} = e.value
    end
  end

  describe "raise-continuable" do
    test "handler return value becomes the raise-continuable result" do
      assert run(~S|
               (with-exception-handler
                 (lambda (c) (* c 10))
                 (lambda () (+ 1 (raise-continuable 5))))|) == 51
    end

    test "handler stack is restored after raise-continuable returns" do
      # After the first raise-continuable returns, the handler is
      # still in place, so a second raise-continuable hits the same
      # handler again.
      assert run(~S|
               (with-exception-handler
                 (lambda (c) (* c 2))
                 (lambda ()
                   (+ (raise-continuable 3)
                      (raise-continuable 4))))|) == 14
    end

    test "raise-continuable with no handler installed escapes to the host" do
      e = assert_raise Schooner.Error, fn -> run("(raise-continuable 'oops)") end
      assert e.value == Value.symbol("oops")
    end
  end

  describe "error-object-irritants type-check" do
    test "raises a type error when called with a non-error-object" do
      e = assert_raise Schooner.Primitive.Error, fn -> run("(error-object-irritants 1)") end

      assert match?(
               {:type_error, "error-object-irritants", "error object", _},
               e.reason
             )
    end
  end

  describe "guard" do
    test "matching clause's value becomes the guard form's value" do
      assert run(~S|
               (guard (c ((symbol? c) 'got-symbol)
                         ((number? c) 'got-number))
                 (raise 42))|) == Value.symbol("got-number")
    end

    test "no clause matches → re-raise to outer handler" do
      assert run(~S|
               (guard (c ((symbol? c) 'outer-saw-symbol))
                 (guard (c ((number? c) 'inner-saw-number))
                   (raise 'oops)))|) == Value.symbol("outer-saw-symbol")
    end

    test "else clause acts as catch-all" do
      assert run(~S|
               (guard (c ((number? c) 'num)
                         (else 'else-fired))
                 (raise 'sym))|) == Value.symbol("else-fired")
    end

    test "=> arrow form receives the test value" do
      assert run(~S|
               (guard (c ((assv c '((a . 1) (b . 2))) => cdr)
                         (else 'no-match))
                 (raise 'b))|) == 2
    end

    test "guard body returning normally yields its value" do
      assert run("(guard (c (#t 'ignored)) 1 2 3)") == 3
    end

    test "no clause matches and no outer handler → escapes to host" do
      e =
        assert_raise Schooner.Error, fn ->
          run(~S|(guard (c ((symbol? c) 'sym)) (raise 99))|)
        end

      assert e.value == 99
    end

    test "var binds the raised value inside clauses" do
      assert run(~S|
               (guard (c (#t (cons 'got c)))
                 (raise '(1 2 3)))|) == Value.pair(Value.symbol("got"), Value.list([1, 2, 3]))
    end

    test "nested guard escapes only the inner form" do
      assert run(~S|
               (+ 100
                  (guard (c ((number? c) c))
                    (raise 5)))|) == 105
    end
  end

  describe "TCO + exceptions" do
    test "handler installed across deeply nested tail calls is reached without stack growth" do
      # 100k iterations of a tail-recursive loop, then raise. The
      # handler is installed by the surrounding `with-exception-handler`;
      # the BEAM stack must stay bounded both during the loop and
      # during the raise's handler walk.
      depth = 100_000

      source = """
      (guard (c (#t c))
        (let loop ((n #{depth}))
          (if (= n 0)
              (raise 'reached)
              (loop (- n 1)))))
      """

      result = run(source)
      assert result == Value.symbol("reached")

      {:total_heap_size, heap} = Process.info(self(), :total_heap_size)
      assert heap < 5_000_000, "heap grew to #{heap} words — TCO likely broken"
    end
  end
end

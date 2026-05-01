defmodule Schooner.Primitives.ParametersTest do
  use ExUnit.Case, async: true

  alias Schooner.Value

  defp run(source), do: Schooner.run!(source)

  describe "make-parameter" do
    test "without converter, initial value is the supplied init" do
      assert run("(define p (make-parameter 42)) (p)") == 42
    end

    test "with converter, initial value is converted" do
      assert run(~S|
               (define p (make-parameter 5 (lambda (x) (* x x))))
               (p)|) == 25
    end

    test "the parameter is a procedure" do
      assert run("(procedure? (make-parameter 1))") == Value.bool(true)
    end

    test "two distinct parameters are not eq?" do
      assert run("(eq? (make-parameter 1) (make-parameter 1))") == Value.bool(false)
    end

    test "the same parameter is eq? to itself" do
      assert run("(define p (make-parameter 1)) (eq? p p)") == Value.bool(true)
    end

    test "calling a parameter with arguments raises arity mismatch" do
      assert_raise Schooner.Eval.Error, ~r/arity mismatch in `parameter`/, fn ->
        run("((make-parameter 1) 2)")
      end
    end

    test "make-parameter with zero arguments raises arity mismatch" do
      assert_raise Schooner.Eval.Error, ~r/at least 1/, fn ->
        run("(make-parameter)")
      end
    end

    test "make-parameter with three arguments raises arity mismatch" do
      assert_raise Schooner.Eval.Error, ~r/at most 2/, fn ->
        run("(make-parameter 1 (lambda (x) x) 3)")
      end
    end

    test "make-parameter with non-procedure converter raises a type error" do
      assert_raise Schooner.Primitive.Error, ~r/expected procedure/, fn ->
        run("(make-parameter 1 42)")
      end
    end

    test "converter that errors during make-parameter propagates" do
      assert_raise Schooner.Error, fn ->
        run(~S|(make-parameter 1 (lambda (x) (error "no")))|)
      end
    end
  end

  describe "parameterize" do
    test "shadows the parameter for the dynamic extent of the body" do
      assert run(~S|
               (define p (make-parameter 1))
               (parameterize ((p 99)) (p))|) == 99
    end

    test "restores the original value after the body returns" do
      assert run(~S|
               (define p (make-parameter 1))
               (parameterize ((p 99)) (p))
               (p)|) == 1
    end

    test "applies the converter to each parameterize value" do
      assert run(~S|
               (define p (make-parameter 0 (lambda (x) (* x 10))))
               (parameterize ((p 7)) (p))|) == 70
    end

    test "leaves the parameter unaffected outside the body even with a converter" do
      # The init is converted (5 -> 25); the parameterize value (3 -> 9) holds
      # only inside the body. Verifies that restoration carries the
      # *converted* init back, not the raw init.
      assert run(~S|
               (define p (make-parameter 5 (lambda (x) (* x x))))
               (list (p) (parameterize ((p 3)) (p)) (p))|) ==
               Value.list([25, 9, 25])
    end

    test "nested parameterize uses the innermost binding" do
      assert run(~S|
               (define p (make-parameter 1))
               (parameterize ((p 2)) (parameterize ((p 3)) (p)))|) == 3
    end

    test "nested parameterize restores the outer binding after the inner exits" do
      assert run(~S|
               (define p (make-parameter 1))
               (parameterize ((p 2))
                 (parameterize ((p 3)) (p))
                 (p))|) == 2
    end

    test "binds multiple parameters at once" do
      assert run(~S|
               (define p (make-parameter 1))
               (define q (make-parameter 10))
               (parameterize ((p 2) (q 20)) (+ (p) (q)))|) == 22
    end

    test "empty bindings list runs the body and returns its value" do
      assert run("(parameterize () 42)") == 42
    end

    test "evaluates body in left-to-right order, returning last value" do
      assert run(~S|
               (define p (make-parameter 1))
               (parameterize ((p 5))
                 (* (p) 2)
                 (+ (p) 100))|) == 105
    end

    test "the parameter stack is restored when the body errors out" do
      # First call errors out inside parameterize; the host catches the
      # Schooner.Error. The next call must see p restored to its initial
      # value — `Schooner.eval/2`'s top-level reset guarantees this even
      # without the parameterize `after` clause, but together they belt-
      # and-brace each escape path.
      assert_raise Schooner.Error, fn ->
        run(~S|(define p (make-parameter 1))
               (parameterize ((p 99)) (error "boom"))|)
      end

      assert run("(define p (make-parameter 1)) (p)") == 1
    end

    test "non-parameter in a binding position raises a type error" do
      assert_raise Schooner.Primitive.Error, ~r/expected parameter/, fn ->
        run("(parameterize ((42 0)) 1)")
      end
    end

    test "parameter values inside parameterize are visible to procedures called from the body" do
      assert run(~S|
               (define p (make-parameter 1))
               (define (read-p) (p))
               (parameterize ((p 99)) (read-p))|) == 99
    end

    test "a parameter created inside parameterize sees its own init, not a shadowed one" do
      assert run(~S|
               (define p (make-parameter 1))
               (parameterize ((p 99))
                 (let ((q (make-parameter 7)))
                   (q)))|) == 7
    end

    test "%parameterize-apply rejects a non-list bindings argument" do
      # `parameterize` macro always builds a proper list, but the runtime
      # primitive is exposed and must reject callers that hand it junk.
      assert_raise Schooner.Primitive.Error, ~r/list of \(parameter . value\) pairs/, fn ->
        run("(%parameterize-apply 'not-a-list (lambda () 1))")
      end
    end
  end
end

defmodule Schooner.Conformance.R7rsSection53DefinitionsTest do
  # Worked examples from r7rs-small §5.3 (definitions). Each test
  # transcribes the spec's `(form) ==> result` example or pins a
  # property the spec calls out as required of `define-values`.
  #
  # `define` itself is exercised throughout the §4 conformance file;
  # this file focuses on §5.3.2 `define-values`. Both top-level and
  # internal-definition positions are covered, since Schooner
  # implements them via different mechanisms (top-level `Env.define`
  # vs. body desugarer fan-out into a `letrec*` multi-binding).
  use ExUnit.Case, async: true

  alias Schooner.Value

  defp run(source), do: Schooner.run!(source)

  describe "§5.3.2 define-values" do
    # Spec example:
    #   (define-values (x y) (values 1 2))
    #   (+ x y) ==> 3
    test "(define-values (x y) (values 1 2)); (+ x y) ==> 3" do
      assert run("""
             (define-values (x y) (values 1 2))
             (+ x y)
             """) == 3
    end

    # Spec example:
    #   (define-values (x y . z) (values 1 2 3 4))
    #   (list x y z) ==> (1 2 (3 4))
    test "(define-values (x y . z) (values 1 2 3 4)); (list x y z) ==> (1 2 (3 4))" do
      assert run("""
             (define-values (x y . z) (values 1 2 3 4))
             (list x y z)
             """) == Value.list([1, 2, Value.list([3, 4])])
    end

    # Spec example:
    #   (define-values all (values 1 2 3))
    #   all ==> (1 2 3)
    test "(define-values all (values 1 2 3)); all ==> (1 2 3)" do
      assert run("""
             (define-values all (values 1 2 3))
             all
             """) == Value.list([1, 2, 3])
    end

    test "internal define-values is mutually recursive with surrounding internal defines" do
      assert run("""
             (define (f)
               (define-values (a b) (values 1 2))
               (define c (+ a b))
               c)
             (f)
             """) == 3
    end

    test "define-values with empty formals accepts (values)" do
      assert run("""
             (define-values () (values))
             'ok
             """) == Value.symbol("ok")
    end
  end
end

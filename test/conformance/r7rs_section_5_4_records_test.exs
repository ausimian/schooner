defmodule Schooner.Conformance.R7rsSection54RecordsTest do
  # Worked examples from r7rs-small §5.4 (record-type definitions).
  # Each test transcribes a `(form) ==> result` example from the
  # spec or pins a property the spec calls out as required of a
  # `define-record-type` implementation.
  #
  # Schooner-specific deviations from §5.4:
  #
  #   - Field mutators (the third element of a `(field accessor
  #     mutator)` clause) are not supported. The grammar accepts
  #     only `(field accessor)`; a mutator clause is a syntax error.
  #     This is the no-mutation constraint that runs through the
  #     whole language, not a record-system limitation per se.
  use ExUnit.Case, async: true

  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "§5.4 the canonical kons example" do
    # Spec example:
    #   (define-record-type <pare>
    #     (kons x y)
    #     pare?
    #     (x kar)
    #     (y kdr))
    test "constructor produces a record; predicate distinguishes it from cons cells" do
      assert run("""
             (define-record-type <pare> (kons x y) pare? (x kar) (y kdr))
             (define p (kons 1 2))
             (list (pare? p) (pare? (cons 1 2)) (kar p) (kdr p))
             """) ==
               Value.list([
                 Value.bool(true),
                 Value.bool(false),
                 1,
                 2
               ])
    end

    test "predicate rejects non-records" do
      assert run("""
             (define-record-type <pare> (kons x y) pare? (x kar) (y kdr))
             (list (pare? 'p) (pare? "string") (pare? 99) (pare? '()))
             """) ==
               Value.list([
                 Value.bool(false),
                 Value.bool(false),
                 Value.bool(false),
                 Value.bool(false)
               ])
    end
  end

  describe "§5.4 partial constructor" do
    test "constructor can mention only a subset of the declared fields" do
      assert run("""
             (define-record-type pt
               (only-x x)
               pt?
               (x get-x)
               (y get-y))
             (define p (only-x 7))
             (list (get-x p) (get-y p))
             """) == Value.list([7, :unspecified])
    end
  end

  describe "§5.4 type identity" do
    test "two record-type definitions with the same name produce distinct types" do
      # The spec is explicit that each `define-record-type` form
      # introduces a *new* type, even if the syntactic name is the
      # same as a previous definition.
      assert run("""
             (define-record-type same-name (mk-a) a?)
             (define a-instance (mk-a))
             (define-record-type same-name (mk-b) b?)
             (define b-instance (mk-b))
             (list (a? a-instance) (a? b-instance) (b? a-instance) (b? b-instance))
             """) ==
               Value.list([
                 Value.bool(true),
                 Value.bool(false),
                 Value.bool(false),
                 Value.bool(true)
               ])
    end
  end

  describe "§5.4 records and equality" do
    test "two records of the same type are equal? when their fields are equal?" do
      assert run("""
             (define-record-type pt (mk x y) pt? (x px) (y py))
             (equal? (mk 1 2) (mk 1 2))
             """) == Value.bool(true)
    end

    test "records compare structurally when nested" do
      assert run("""
             (define-record-type box (mk-box v) box? (v unbox))
             (equal? (mk-box (list 1 (mk-box 2))) (mk-box (list 1 (mk-box 2))))
             """) == Value.bool(true)
    end
  end
end

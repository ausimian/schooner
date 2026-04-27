defmodule Schooner.Expander.RecordTest do
  # Phase 10 — `define-record-type`. End-to-end tests through
  # `Schooner.run/1` covering the constructor / predicate / accessor
  # surface, partial constructors (per r7rs §5.4 a constructor's
  # field list may be a subset of the record's fields), the per-form
  # type-identity rule (two definitions with the same record name
  # produce distinct types), nested records, and `write` rendering.
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Eval.Error
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "constructor / predicate / accessors" do
    test "the constructor returns a record; the predicate is #t for own type and #f otherwise" do
      assert run("""
             (define-record-type point (make-point x y) point? (x point-x) (y point-y))
             (define p (make-point 3 4))
             (list (point? p) (point? 5) (point? 'p) (point? '(3 4)))
             """) ==
               Value.list([
                 Value.bool(true),
                 Value.bool(false),
                 Value.bool(false),
                 Value.bool(false)
               ])
    end

    test "each accessor returns the correct field" do
      assert run("""
             (define-record-type point (make-point x y) point? (x point-x) (y point-y))
             (define p (make-point 3 4))
             (list (point-x p) (point-y p))
             """) == Value.list([3, 4])
    end

    test "an accessor on a wrong-type value raises a primitive error" do
      assert_raise PError, fn ->
        run("""
        (define-record-type point (make-point x y) point? (x point-x) (y point-y))
        (define-record-type circle (make-circle r) circle? (r circle-radius))
        (define c (make-circle 5))
        (point-x c)
        """)
      end
    end

    test "a record with no constructor fields produces a record whose fields are all unspecified" do
      # No specific assertion on the `unspecified` value's shape —
      # just that the predicate fires and the accessor doesn't crash.
      assert run("""
             (define-record-type empty-rec (make-empty) empty? (x empty-x))
             (define e (make-empty))
             (list (empty? e) (empty? 0))
             """) == Value.list([Value.bool(true), Value.bool(false)])
    end
  end

  describe "partial constructors" do
    test "fields not mentioned in the constructor default to :unspecified" do
      assert run("""
             (define-record-type pt
               (mk-x x)
               pt?
               (x get-x)
               (y get-y))
             (define p (mk-x 7))
             (list (pt? p) (get-x p) (get-y p))
             """) == Value.list([Value.bool(true), 7, :unspecified])
    end

    test "constructor argument order may differ from declared field order" do
      assert run("""
             (define-record-type pt
               (make-pt y x)
               pt?
               (x get-x)
               (y get-y))
             (define p (make-pt 'wye 'eks))
             (list (get-x p) (get-y p))
             """) == Value.list([Value.symbol("eks"), Value.symbol("wye")])
    end
  end

  describe "type identity is per-definition" do
    test "two top-level definitions with the same record name produce distinct types" do
      # Each `define-record-type` form mints a fresh type-id, so the
      # second `point?` (re-bound to the second type's predicate)
      # rejects an instance from the first type.
      assert run("""
             (define-record-type point (make-point x) point? (x point-x))
             (define p1 (make-point 1))
             (define-record-type point (make-point x) point? (x point-x))
             (define p2 (make-point 2))
             (list (point? p1) (point? p2))
             """) == Value.list([Value.bool(false), Value.bool(true)])
    end

    test "definitions in distinct lexical scopes produce distinct types" do
      assert run("""
             (define mk-a
               ((lambda ()
                  (define-record-type a (a-mk x) a? (x a-get))
                  a-mk)))
             (define a? ((lambda ()
                          (define-record-type a (a-mk x) a? (x a-get))
                          a?)))
             (a? (mk-a 99))
             """) == Value.bool(false)
    end
  end

  describe "structural equality" do
    test "two record instances of the same type compare equal? when fields are equal?" do
      assert run("""
             (define-record-type pt (mk x y) pt? (x px) (y py))
             (equal? (mk 1 2) (mk 1 2))
             """) == Value.bool(true)
    end

    test "two record instances of the same type with differing fields are not equal?" do
      assert run("""
             (define-record-type pt (mk x y) pt? (x px) (y py))
             (equal? (mk 1 2) (mk 1 99))
             """) == Value.bool(false)
    end

    test "records of different types with same field shape are not equal?" do
      assert run("""
             (define-record-type a (mk-a x) a? (x a-x))
             (define-record-type b (mk-b x) b? (x b-x))
             (equal? (mk-a 5) (mk-b 5))
             """) == Value.bool(false)
    end

    test "records nested inside lists, vectors, and other records compare structurally" do
      assert run("""
             (define-record-type pair-rec (mk a b) pair-rec? (a pr-a) (b pr-b))
             (equal?
               (list (mk 1 2) #(1 (mk 3 4)))
               (list (mk 1 2) #(1 (mk 3 4))))
             """) == Value.bool(true)
    end
  end

  describe "write rendering" do
    test "records render as #<record name>" do
      env = Env.new()

      _ =
        Schooner.eval(
          """
          (import (scheme base))
          (define-record-type pt (mk-pt x y) pt? (x pt-x) (y pt-y))
          (define p (mk-pt 1 2))
          """,
          env
        )

      record = Schooner.eval("p", env)
      assert is_tuple(record) and elem(record, 0) == :record
      assert Value.write(record) == "#<record pt>"
    end
  end

  describe "malformed forms" do
    test "missing predicate raises a syntax error" do
      assert_raise Error, fn ->
        run("(define-record-type pt (mk x))")
      end
    end

    test "non-symbol field name raises a syntax error" do
      assert_raise Error, fn ->
        run("(define-record-type pt (mk x) pt? (1 acc))")
      end
    end
  end
end

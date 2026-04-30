defmodule Schooner.Primitives.BaseVectorsTest do
  use ExUnit.Case, async: true

  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  describe "constructors" do
    test "(vector ...) builds a vector" do
      assert run("(vector)") == Value.vector([])
      assert run("(vector 1 2 3)") == Value.vector([1, 2, 3])
    end

    test "make-vector with fill" do
      assert run("(make-vector 3 0)") == Value.vector([0, 0, 0])
      assert run("(make-vector 0 0)") == Value.vector([])
    end

    test "make-vector without fill defaults to :unspecified" do
      assert run("(make-vector 2)") == Value.vector([:unspecified, :unspecified])
    end

    test "make-vector negative size raises" do
      e = assert_raise PError, fn -> run("(make-vector -1 0)") end
      assert match?({:invalid_size, "make-vector", _}, e.reason)
    end
  end

  describe "vector-length / vector-ref" do
    test "vector-length" do
      assert run("(vector-length #(1 2 3 4))") === 4
      assert run("(vector-length #())") === 0
    end

    test "vector-ref" do
      assert run("(vector-ref #(a b c) 0)") == Value.symbol("a")
      assert run("(vector-ref #(a b c) 2)") == Value.symbol("c")
    end

    test "vector-ref out of range raises" do
      e = assert_raise PError, fn -> run("(vector-ref #(1 2 3) 5)") end
      assert match?({:index_out_of_range, "vector-ref", _, _}, e.reason)

      assert_raise PError, fn -> run("(vector-ref #(1 2 3) -1)") end
    end
  end

  describe "vector <-> list" do
    test "vector->list and list->vector round-trip" do
      assert run("(list->vector (vector->list #(1 2 3)))") == Value.vector([1, 2, 3])

      assert run("(vector->list (list->vector '(a b c)))") ==
               Value.list([Value.symbol("a"), Value.symbol("b"), Value.symbol("c")])
    end

    test "vector->list with start / end slice" do
      assert run("(vector->list #(0 1 2 3 4) 1 4)") == Value.list([1, 2, 3])
      assert run("(vector->list #(0 1 2 3) 2)") == Value.list([2, 3])
    end
  end

  describe "vector-map / vector-for-each" do
    test "vector-map applies pointwise" do
      assert run("(vector-map (lambda (x) (* x 2)) #(1 2 3))") == Value.vector([2, 4, 6])
    end

    test "vector-map with multiple vectors uses the shortest length" do
      assert run("(vector-map + #(1 2 3) #(10 20 30 40))") == Value.vector([11, 22, 33])
    end

    test "vector-for-each returns unspecified" do
      assert run("(vector-for-each (lambda (x) x) #(1 2 3))") == :unspecified
    end
  end

  describe "vector-copy" do
    test "produces a structurally equal but not identity-equal vector" do
      assert run("(equal? #(1 2 3) (vector-copy #(1 2 3)))") == Value.bool(true)
      assert run("(equal? #(1 2 3) (vector-copy #(4 5 6)))") == Value.bool(false)
      assert run("(let ((v #(1 2 3))) (eq? v (vector-copy v)))") == Value.bool(false)
      assert run("(let ((v #(1 2 3))) (eq? v v))") == Value.bool(true)
    end

    test "vector-copy with start / end" do
      assert run("(vector-copy #(0 1 2 3 4) 1 4)") == Value.vector([1, 2, 3])
      assert run("(vector-copy #(0 1 2 3) 2)") == Value.vector([2, 3])
    end

    test "out-of-range bounds raise" do
      e = assert_raise PError, fn -> run("(vector-copy #(1 2 3) 0 10)") end
      assert match?({:index_out_of_range, "vector-copy", _, _}, e.reason)
    end
  end

  describe "vector-append" do
    test "concatenates vectors" do
      assert run("(vector-append)") == Value.vector([])
      assert run("(vector-append #(1 2) #(3 4))") == Value.vector([1, 2, 3, 4])
      assert run("(vector-append #(1) #() #(2))") == Value.vector([1, 2])
    end

    test "non-vector argument raises" do
      e = assert_raise PError, fn -> run("(vector-append #(1 2) 3)") end
      assert match?({:type_error, "vector-append", "vector", _}, e.reason)
    end
  end
end

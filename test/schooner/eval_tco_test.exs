defmodule Schooner.EvalTcoTest do
  @moduledoc """
  Regression tests for proper-tail-call behaviour. Each test recurses
  100 000 calls deep and asserts both that the call returns and that
  the process heap stays bounded — i.e. the tail calls really did
  collapse rather than each pushing a frame.
  """

  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Value

  @depth 100_000

  defp depth, do: @depth

  defp env_with_int_prims do
    Env.new()
    |> Env.define(
      "zero-int?",
      Value.primitive("zero-int?", 1, fn [n] -> Value.bool(n === 0) end)
    )
    |> Env.define("sub1", Value.primitive("sub1", 1, fn [n] -> n - 1 end))
  end

  defp run!(source), do: Schooner.eval!(source, env_with_int_prims())

  defp assert_bounded_heap(fun) do
    fun.()
    {:total_heap_size, heap} = Process.info(self(), :total_heap_size)
    # 100k stacked frames would blow well past this; ~5M words is generous.
    assert heap < 5_000_000, "heap grew to #{heap} words — TCO likely broken"
  end

  test "tail call as the entire lambda body" do
    assert_bounded_heap(fn ->
      assert run!("""
             (define (loop n)
               (if (zero-int? n) 'done (loop (sub1 n))))
             (loop #{depth()})
             """) == Value.symbol("done")
    end)
  end

  test "tail call in if then-branch" do
    assert_bounded_heap(fn ->
      assert run!("""
             (define (loop n)
               (if (zero-int? n)
                   'done
                   (loop (sub1 n))))
             (loop #{depth()})
             """) == Value.symbol("done")
    end)
  end

  test "tail call in if else-branch (inverted predicate)" do
    env =
      env_with_int_prims()
      |> Env.define(
        "nonzero-int?",
        Value.primitive("nonzero-int?", 1, fn [n] -> Value.bool(n !== 0) end)
      )

    source = """
    (define (loop n)
      (if (nonzero-int? n)
          (loop (sub1 n))
          'done))
    (loop #{depth()})
    """

    assert_bounded_heap(fn ->
      assert Schooner.eval!(source, env) == Value.symbol("done")
    end)
  end

  test "tail call as the last form of begin" do
    assert_bounded_heap(fn ->
      assert run!("""
             (define (loop n)
               (begin
                 'discard
                 (if (zero-int? n) 'done (loop (sub1 n)))))
             (loop #{depth()})
             """) == Value.symbol("done")
    end)
  end

  test "mutually tail-recursive even?/odd? at depth" do
    assert_bounded_heap(fn ->
      assert run!("""
             (define (even? n)
               (if (zero-int? n) #t (odd? (sub1 n))))
             (define (odd? n)
               (if (zero-int? n) #f (even? (sub1 n))))
             (even? #{depth()})
             """) == Value.bool(true)
    end)
  end

  test "named let recurses tail-call style at depth" do
    assert_bounded_heap(fn ->
      assert run!("""
             (let loop ((n #{depth()}))
               (if (zero-int? n) 'done (loop (sub1 n))))
             """) == Value.symbol("done")
    end)
  end

  test "letrec-bound mutually recursive lambdas tail-call at depth" do
    assert_bounded_heap(fn ->
      assert run!("""
             (letrec ((even? (lambda (n) (if (zero-int? n) #t (odd? (sub1 n)))))
                      (odd?  (lambda (n) (if (zero-int? n) #f (even? (sub1 n))))))
               (even? #{depth()}))
             """) == Value.bool(true)
    end)
  end
end

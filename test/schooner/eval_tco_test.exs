defmodule Schooner.EvalTcoTest do
  @moduledoc """
  Regression tests for proper-tail-call behaviour. Each test recurses
  at least 100 000 calls deep and asserts both that the call returns and that
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

  test "tail loop with non-lambda internal definitions stays within a heap limit" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        env = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
        Process.flag(:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false})

        result =
          Schooner.eval!(
            """
            (define (loop n)
              (define k (+ n 0))
              (if (= k 0) 'done (loop (- k 1))))
            (loop #{depth()})
            """,
            env
          )

        slots = Enum.count(Process.get(), fn {_, v} -> match?({:rec_frame, _, _}, v) end)
        send(parent, {:bounded_loop, self(), result, slots})
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 15_000
    assert reason == :normal
    assert_received {:bounded_loop, ^pid, result, 0}
    assert result == Value.symbol("done")
  end

  test "tail loop with callback closures stays within a heap limit" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        env = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
        Process.flag(:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false})

        result =
          Schooner.eval!(
            """
            (define (loop n acc)
              (define k (+ n 1))
              (if (= n 0)
                  (length acc)
                  (loop (- n 1) (map (lambda (x) (+ x k)) acc))))
            (loop 300000 (list 1))
            """,
            env
          )

        slots = Enum.count(Process.get(), fn {_, v} -> match?({:rec_frame, _, _}, v) end)
        send(parent, {:bounded_callback_loop, self(), result, slots})
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 30_000
    assert reason == :normal
    assert_received {:bounded_callback_loop, ^pid, 1, 0}
  end
end

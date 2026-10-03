defmodule Schooner.Eval.SequentialBindingsTest do
  use ExUnit.Case, async: true

  alias Schooner.Eval.Error
  alias Schooner.Value

  defp env, do: Schooner.Environment.new(pre_imports: [["scheme", "base"]])

  defp compiled(source), do: Schooner.compile!(source, env())

  defp shape(source), do: source |> compiled() |> Map.fetch!(:program) |> List.last() |> elem(0)

  defp eval!(source), do: Schooner.eval!(source, env())

  defp count_rec_slots do
    Enum.count(Process.get(), fn {_, value} -> match?({:rec_frame, _, _}, value) end)
  end

  # Internal definitions live inside a lambda, so inspect its body node.
  defp internal_shape(body) do
    %Schooner.Compiled{program: [{:lambda, _, {_, [node]}, _}]} =
      compiled("(lambda () #{body})")

    elem(node, 0)
  end

  test "accepted because later value inits only read earlier bindings" do
    source = "(letrec* ((a 1) (b (+ a 10)) (c (+ b 100))) (list a b c))"
    assert shape(source) == :letseq
    before = count_rec_slots()
    assert eval!(source) == Value.list([1, 11, 111])
    assert count_rec_slots() == before
  end

  test "accepted because an escaping init closure only captures an earlier binding" do
    source = "(letrec* ((x 42) (get (lambda () x))) get)"
    assert shape(source) == :letseq
    before = count_rec_slots()
    closure = eval!(source)
    assert count_rec_slots() == before
    assert Schooner.apply(closure, []) == {:ok, 42}

    for wrapped <- ["(define x 99) #{source}", "((lambda (x) #{source}) 99)"] do
      assert Schooner.apply(eval!(wrapped), []) == {:ok, 42}
    end
  end

  test "accepted because nested lambdas in a later init only reference earlier bindings" do
    source = "(letrec* ((x 42) (make (lambda () (lambda () x)))) (make))"
    assert shape(source) == :letseq
    closure = eval!(source)
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "accepted because multi-value inits only read earlier bindings" do
    body = """
    (define a 40)
    (define-values (b c . rest) (values (+ a 1) (+ a 2) 3 4))
    (define-values all (values b c))
    (define-values () (values))
    (list a b c rest all)
    """

    assert internal_shape(body) == :letseq

    assert eval!("((lambda () #{body}))") ==
             Value.list([40, 41, 42, Value.list([3, 4]), Value.list([41, 42])])
  end

  test "rejected because a multi-value init reads its own targets" do
    body = "(define-values (a b) (values b 1)) a"
    assert internal_shape(body) == :letrec
    error = assert_raise Error, fn -> eval!("((lambda () #{body}))") end
    assert error.reason == {:rec_uninitialised, "b"}
  end

  test "accepted because a multi-value init closure only captures an earlier binding" do
    body = """
    (define x 42)
    (define-values (get number) (values (lambda () x) 7))
    get
    """

    assert internal_shape(body) == :letseq
    closure = eval!("((lambda () #{body}))")
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "accepted because a multi-value init has no recursive references, preserving arity errors" do
    body = "(define-values (a b) (values 1)) a"
    assert internal_shape(body) == :letseq
    error = assert_raise Error, fn -> eval!("((lambda () #{body}))") end
    assert error.reason == {:arity_mismatch, "define-values", {:exact, 2}, 1}
  end

  test "accepted because later inits read the earlier binding that shadows the outer name" do
    form = "(letrec* ((x 1) (y x)) (list x y))"
    assert shape(form) == :letseq
    assert eval!("(define x 99) #{form}") == Value.list([1, 1])
    assert eval!("((lambda (x) #{form}) 99)") == Value.list([1, 1])
  end

  test "rejected because self and forward references must not read an outer name" do
    for {bindings, name} <- [{"((x x))", "x"}, {"((x y) (y 1))", "y"}] do
      source = "(letrec* #{bindings} x)"
      assert shape(source) == :letrec
      error = assert_raise Error, fn -> eval!("(define #{name} 99) #{source}") end
      assert error.reason == {:rec_uninitialised, name}
    end
  end

  test "rejected because duplicate targets need recursive-frame writes" do
    source = "(letrec* ((x 1) (x 2)) x)"
    assert shape(source) == :letrec
    assert eval!(source) == 2

    body = "(define-values (x x) (values 1 2)) x"
    assert internal_shape(body) == :letrec
    assert eval!("((lambda () #{body}))") == 2
  end

  test "accepted because a returned body closure captures the fully initialized frame" do
    source = "(letrec* ((x 42)) (lambda () x))"
    assert shape(source) == :letseq
    before = count_rec_slots()
    closure = eval!(source)
    assert count_rec_slots() == before
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "accepted because a stashed body closure captures the fully initialized frame" do
    parent = self()

    environment =
      Schooner.Environment.new(
        pre_imports: [["scheme", "base"]],
        libraries: [
          Schooner.Host.library(
            primitives: [
              {"stash", 1,
               fn [closure] ->
                 send(parent, {:stashed, closure})
                 0
               end}
            ]
          )
        ]
      )

    source = "(define x 99) (letrec* ((x 42)) (stash (lambda () x)) 0)"
    %Schooner.Compiled{program: program} = Schooner.compile!(source, environment)
    assert program |> List.last() |> elem(0) == :letseq
    before = count_rec_slots()
    assert Schooner.eval!(source, environment) == 0
    assert count_rec_slots() == before
    assert_received {:stashed, closure}
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "accepted because nested frames and guard clauses only reference earlier bindings" do
    source = """
    (letrec* ((x 40)
              (y (letrec* ((z (+ x 1))) z))
              (answer (guard (e (else (+ y 1))) (raise 'recover))))
      (list x y answer))
    """

    assert shape(source) == :letseq
    assert eval!(source) == Value.list([40, 41, 42])
  end

  test "accepted because quoted lambda data contains no executable references" do
    source = "(letrec* ((x '(lambda () x)) (y x)) (eq? x y))"
    assert shape(source) == :letseq
    assert eval!(source) == true
  end

  test "accepted because nested direct recursive calls only reference initialized bindings" do
    init_source = """
    (letrec* ((x 42)
              (answer (let loop ((n 3))
                        (if (= n 0) x (loop (- n 1))))))
      answer)
    """

    %Schooner.Compiled{
      program: [{:letseq, _, [{:single, 0, _}, {:single, 1, {:fixrec, _, _}}], _}]
    } = compiled(init_source)

    assert eval!(init_source) == 42

    body_source = """
    (letrec* ((x 42))
      (let loop ((n 3))
        (if (= n 0) (lambda () x) (loop (- n 1)))))
    """

    %Schooner.Compiled{program: [{:letseq, _, _, [{:fixrec, _, _}]}]} = compiled(body_source)
    closure = eval!(body_source)
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "rejected as positional because a named loop references itself, using direct calls" do
    source = """
    (let loop ((n 10))
      (define k (+ n 0))
      (if (= k 0) 'done (loop (- k 1))))
    """

    assert shape(source) == :fixrec
    assert eval!(source) == Value.symbol("done")
  end

  test "accepted because an escaping loop-body closure captures the final initialized frame" do
    body = """
    (define k (+ n 42))
    (if (= n 0) (lambda () k) (loop (- n 1)))
    """

    assert internal_shape(body) == :letseq
    before = count_rec_slots()
    closure = eval!("(define (loop n) #{body}) (loop 1000)")
    assert count_rec_slots() == before
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "rejected because an escaping init closure refers to its own binding" do
    source = """
    (letrec* ((f (lambda (n) (if (= n 0) 42 (f (- n 1))))))
      f)
    """

    assert shape(source) == :letrec
    before = count_rec_slots()
    closure = eval!(source)
    assert count_rec_slots() == before + 1
    assert Schooner.apply(closure, [100]) == {:ok, 42}
  end

  test "rejected because escaping init closures refer to mutually recursive bindings" do
    source = """
    (letrec* ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
              (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))
      even?)
    """

    assert shape(source) == :letrec
    before = count_rec_slots()
    closure = eval!(source)
    assert count_rec_slots() == before + 1
    assert Schooner.apply(closure, [100]) == {:ok, true}
    assert Schooner.apply(closure, [101]) == {:ok, false}
  end

  test "rejected because a nested init lambda refers to a later binding" do
    source = "(letrec* ((make (lambda () (lambda () x))) (x 42)) (make))"
    assert shape(source) == :letrec
    closure = eval!(source)
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "rejected because a multi-value init closure refers to a sibling target" do
    body = "(define-values (get x) (values (lambda () x) 42)) get"
    assert internal_shape(body) == :letrec
    closure = eval!("((lambda () #{body}))")
    assert Schooner.apply(closure, []) == {:ok, 42}
  end

  test "rejected because a nested direct-recursion body references the current or a later binding" do
    for bindings <- [
          "((x (let loop ((n 1)) (if (= n 0) x (loop (- n 1))))))",
          "((x (let loop ((n 1)) (if (= n 0) y (loop (- n 1))))) (y 42))"
        ] do
      source = "(letrec* #{bindings} x)"

      %Schooner.Compiled{program: [{:letrec, _, [{:single, 0, {:fixrec, _, _}} | _], _}]} =
        compiled(source)

      error = assert_raise Error, fn -> eval!(source) end
      name = if String.contains?(bindings, "(y 42)"), do: "y", else: "x"
      assert error.reason == {:rec_uninitialised, name}
    end
  end

  test "accepted because lambda parameters shadow candidate names at their own depth" do
    source = "(letrec* ((x (lambda (x) x))) (x 42))"
    assert shape(source) == :letseq
    assert eval!(source) == 42
  end

  test "accepted because a nested recursive init closure only references an earlier outer binding" do
    source = """
    (letrec* ((x 42)
              (get (letrec* ((f (lambda (n)
                                 (if (= n 0) x (f (- n 1))))))
                     f)))
      get)
    """

    %Schooner.Compiled{
      program: [{:letseq, _, [{:single, 0, _}, {:single, 1, {:letrec, _, _, _}}], _}]
    } = compiled(source)

    before = count_rec_slots()
    closure = eval!(source)
    assert count_rec_slots() == before + 1
    assert Schooner.apply(closure, [100]) == {:ok, 42}
  end
end

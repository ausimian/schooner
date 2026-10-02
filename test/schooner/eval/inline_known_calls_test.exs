defmodule Schooner.Eval.InlineKnownCallsTest do
  @moduledoc """
  Two evaluator fast paths that must be invisible to Scheme code:

    * two-argument calls to the standard `+ - * = < > <= >=` run the
      integer operation inline, but only while the procedure the call
      site looks up is still the standard one;
    * a `letrec*` (named `let`, internal defines) whose lambdas are only
      ever called directly is compiled to `:fixrec` / `:known_call`
      with no closures, and anything else keeps the general path.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  defp env, do: Schooner.Environment.new(pre_imports: [["scheme", "base"]])

  defp eval!(src), do: Schooner.eval!(src, env())

  # The tag of the outermost IR node of the program's last form.
  defp shape(src) do
    %Schooner.Compiled{program: program} = Schooner.compile!(src, env())
    program |> List.last() |> elem(0)
  end

  # Tags of every node in the program's IR.
  defp tags(src) do
    %Schooner.Compiled{program: program} = Schooner.compile!(src, env())
    program |> collect_tags() |> MapSet.new()
  end

  defp collect_tags(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)),
    do: [elem(t, 0) | t |> Tuple.to_list() |> tl() |> collect_tags()]

  defp collect_tags(t) when is_tuple(t), do: t |> Tuple.to_list() |> collect_tags()
  defp collect_tags(l) when is_list(l), do: Enum.flat_map(l, &collect_tags/1)
  defp collect_tags(_), do: []

  describe "inlined arithmetic and comparison" do
    property "agrees with the integer operation" do
      check all(a <- integer(), b <- integer(), op <- member_of(~w(+ - * = < > <= >=))) do
        expected =
          case op do
            "+" -> a + b
            "-" -> a - b
            "*" -> a * b
            "=" -> a == b
            "<" -> a < b
            ">" -> a > b
            "<=" -> a <= b
            ">=" -> a >= b
          end

        assert eval!("(#{op} #{a} #{b})") == expected
      end
    end

    test "non-integer arguments take the general path" do
      assert eval!("(+ 1.5 2)") == 3.5
      assert eval!("(< 1 2.5)") == true
      assert eval!("(= 1 1.0)") == true
      assert eval!("(* 1/2 4)") == 2

      e = assert_raise PError, fn -> eval!("(+ 1 'a)") end
      assert {:type_error, "+", _, _} = e.reason
    end

    test "a multiple-value argument is still rejected" do
      e = assert_raise PError, fn -> eval!("(+ (values 1 2) 1)") end
      assert e.reason == {:wrong_value_count, 2, 1}
    end

    test "a top-level redefinition is honoured, including by earlier closures" do
      assert eval!("""
             (define (f) (+ 1 2))
             (define before (f))
             (define (+ a b) 'mine)
             (list before (+ 1 2) (f))
             """) == Value.list([3, Value.symbol("mine"), Value.symbol("mine")])
    end

    test "a lexical binding of the same name is honoured" do
      assert eval!("(let ((+ -)) (+ 5 3))") == 2
      assert eval!("(define (g < a b) (< a b)) (g > 1 2)") == false
    end

    test "a macro-introduced operator is inlined through its base name" do
      assert eval!("""
             (define-syntax inc (syntax-rules () ((_ x) (+ x 1))))
             (inc 41)
             """) == 42
    end
  end

  describe "known calls" do
    test "a named let becomes a fixrec" do
      assert shape("(let loop ((i 0)) (if (< i 3) (loop (+ i 1)) i))") == :fixrec
      assert eval!("(let loop ((i 0)) (if (< i 3) (loop (+ i 1)) i))") == 3
    end

    test "nested named lets both convert, and the inner loop may call the outer" do
      src = """
      (let outer ((i 0) (acc '()))
        (if (= i 3)
            (reverse acc)
            (let inner ((j 0) (acc acc))
              (if (= j 2) (outer (+ i 1) acc) (inner (+ j 1) (cons (list i j) acc))))))
      """

      refute :letrec in tags(src)
      assert eval!(src) == Value.list(for i <- 0..2, j <- 0..1, do: Value.list([i, j]))
    end

    test "mutually recursive internal defines convert" do
      src = """
      (define (parity n)
        (define (ev? n) (if (= n 0) 'even (od? (- n 1))))
        (define (od? n) (if (= n 0) 'odd (ev? (- n 1))))
        (ev? n))
      (list (parity 10) (parity 7))
      """

      assert :fixrec in tags(src)
      assert eval!(src) == Value.list([Value.symbol("even"), Value.symbol("odd")])
    end

    test "calls from guard clauses and quasiquote resolve the right frame" do
      assert shape("(let loop ((i 0)) (guard (e (#t (loop (+ i 1)))) (if (< i 3) (raise 'x) i)))") ==
               :fixrec

      assert eval!("(let loop ((i 0)) (guard (e (#t (loop (+ i 1)))) (if (< i 3) (raise 'x) i)))") ==
               3

      assert eval!("(let loop ((i 0) (acc '())) (if (= i 2) acc (loop (+ i 1) `(,i . ,acc))))") ==
               Value.list([1, 0])
    end

    test "closures made inside a converted loop still escape and work" do
      src = """
      (let loop ((i 0) (acc '()))
        (if (= i 3) (map (lambda (f) (f)) acc) (loop (+ i 1) (cons (lambda () i) acc))))
      """

      assert shape(src) == :fixrec
      assert eval!(src) == Value.list([2, 1, 0])
    end

    test "using the name as a value keeps the general path" do
      assert shape("(let loop ((i 0)) loop)") == :letrec
      assert {:closure, _, _, _, _} = eval!("(let loop ((i 0)) loop)")

      src = "(let loop ((i 0)) (if (< i 3) (loop (+ i 1)) (procedure? loop)))"
      assert shape(src) == :letrec
      assert eval!(src) == true
    end

    test "a call from inside a nested lambda keeps the general path" do
      src = "(let loop ((i 0)) (if (< i 3) ((lambda () (loop (+ i 1)))) i))"
      assert shape(src) == :letrec
      assert eval!(src) == 3
    end

    test "a call with the wrong argument count keeps the general path and its error" do
      src = "(let loop ((i 0)) (if (< i 3) (loop) i))"
      assert shape(src) == :letrec

      e = assert_raise EvalError, fn -> eval!(src) end
      assert e.reason == {:arity_mismatch, nil, {:exact, 1}, 0}
    end

    test "a variadic lambda keeps the general path" do
      src = "(letrec ((f (lambda args (if (null? args) 'done (f))))) (f 1 2))"
      assert shape(src) == :letrec
      assert eval!(src) == Value.symbol("done")
    end

    test "a converted loop leaves no process-dictionary entries behind" do
      env = env()
      before = length(Process.get())
      assert Schooner.eval!("(let loop ((i 0)) (if (< i 1000) (loop (+ i 1)) i))", env) == 1000
      assert length(Process.get()) == before
    end
  end
end

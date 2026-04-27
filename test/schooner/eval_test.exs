defmodule Schooner.EvalTest do
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Eval.Error
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  # Build an env populated with every variable export from
  # `(scheme base)`. Used by tests that synthesise malformed AST
  # directly and need certain primitives (e.g. `+`) resolvable
  # without going through the eval-time import path.
  defp base_env do
    base = Library.fetch!(Library.standard(), ["scheme", "base"]).exports
    {env, _} = LibImport.apply_bindings(base, Env.new(), SyntaxEnv.new())
    env
  end

  describe "self-evaluating literals" do
    test "integers, floats, booleans, strings, chars, vectors, bytevectors" do
      assert run("42") == 42
      assert run("-7") == -7
      assert run("1.5") == 1.5
      assert run("#t") == Value.bool(true)
      assert run("#f") == Value.bool(false)
      assert run(~S("hello")) == Value.string("hello")
      assert run(~S(#\a)) == Value.char(?a)
      assert run("#(1 2 3)") == Value.vector([1, 2, 3])
      assert run("#u8(0 1 255)") == Value.bytevector([0, 1, 255])
    end

    test "empty input returns :unspecified" do
      assert run("") == :unspecified
    end

    test "() raises empty_application" do
      assert_raise Error, fn -> run("()") end
    end
  end

  describe "variable reference" do
    test "resolves a top-level binding" do
      assert run("(define x 10) x") == 10
    end

    test "unbound variable raises {:unbound, name}" do
      e = assert_raise Error, fn -> run("nope") end
      assert e.reason == {:unbound, "nope"}
    end
  end

  describe "quote" do
    test "returns the datum unchanged" do
      assert run("(quote 5)") == 5
      assert run("'5") == 5
      assert run("'foo") == Value.symbol("foo")
      assert run("'()") == :null
      assert run("'(1 2 3)") == Value.list([1, 2, 3])
    end

    test "quote with wrong arity raises" do
      e = assert_raise Error, fn -> run("(quote)") end
      assert e.reason == {:bad_special_form, "quote"}
    end
  end

  describe "if" do
    test "selects the then-branch when test is truthy" do
      assert run("(if #t 1 2)") == 1
      assert run("(if 0 1 2)") == 1
      assert run("(if '() 1 2)") == 1
      assert run(~S|(if "str" 1 2)|) == 1
    end

    test "only #f is falsy" do
      assert run("(if #f 1 2)") == 2
    end

    test "if without an else branch returns :unspecified on falsy test" do
      assert run("(if #f 1)") == :unspecified
    end

    test "if without an else branch returns then on truthy test" do
      assert run("(if #t 1)") == 1
    end

    test "malformed if raises" do
      e = assert_raise Error, fn -> run("(if)") end
      assert e.reason == {:bad_special_form, "if"}
    end
  end

  describe "lambda" do
    test "evaluates to a closure value" do
      v = run("(lambda (x) x)")
      assert match?({:closure, {:fixed, 1, ["x"]}, _, _, nil}, v)
    end

    test "fixed-arity application" do
      assert run("((lambda (x y) x) 1 2)") == 1
      assert run("((lambda (x y) y) 1 2)") == 2
    end

    test "variadic lambda binds all args to a list" do
      assert run("((lambda args args) 1 2 3)") == Value.list([1, 2, 3])
      assert run("((lambda args args))") == :null
    end

    test "dotted-rest lambda binds head fixed and rest as a list" do
      assert run("((lambda (a . rest) rest) 1 2 3)") == Value.list([2, 3])
      assert run("((lambda (a b . rest) rest) 1 2)") == :null
    end

    test "arity mismatch on fixed lambda raises" do
      e = assert_raise Error, fn -> run("((lambda (x y) x) 1)") end
      assert match?({:arity_mismatch, _, {:exact, 2}, 1}, e.reason)
    end

    test "arity mismatch on dotted-rest lambda raises" do
      e = assert_raise Error, fn -> run("((lambda (a b . r) r) 1)") end
      assert match?({:arity_mismatch, _, {:at_least, 2}, 1}, e.reason)
    end

    test "evaluator rejects malformed lambda parameter lists with :invalid_params" do
      # Synthesise a `(lambda 1 1)` form directly — the expander
      # rejects this kind of shape, but Eval.parse_params/1 has its
      # own catch-all that we want to pin behaviour on.
      bad_head = {:pair, {:sym, "lambda"}, {:pair, 1, {:pair, 1, :null}}}
      e = assert_raise Error, fn -> Schooner.Eval.eval(bad_head, Env.new()) end
      assert e.reason == :invalid_params

      # Non-symbol inside the parameter list reaches collect_params/3.
      bad_param =
        {:pair, {:sym, "lambda"},
         {:pair, {:pair, {:sym, "x"}, {:pair, 1, :null}}, {:pair, {:sym, "x"}, :null}}}

      e = assert_raise Error, fn -> Schooner.Eval.eval(bad_param, Env.new()) end
      assert e.reason == :invalid_params
    end

    test "at-least arity mismatch on dotted-rest lambda raises with {:at_least, _}" do
      e = assert_raise Error, fn -> run("((lambda (a b . r) r) 1)") end
      assert match?({:arity_mismatch, _, {:at_least, 2}, 1}, e.reason)
    end

    test "lambda with empty body raises" do
      e = assert_raise Error, fn -> run("(lambda (x))") end
      assert e.reason == {:bad_special_form, "lambda"}
    end
  end

  describe "define" do
    test "simple define returns :unspecified and binds globally" do
      env = Env.new()
      assert Schooner.eval("(define x 7)", env) == :unspecified
      assert Env.lookup(env, "x") == {:ok, 7}
    end

    test "function-form define binds a named closure" do
      env = Env.new()
      Schooner.eval("(define (f x) x)", env)
      assert {:ok, {:closure, {:fixed, 1, ["x"]}, _, _, "f"}} = Env.lookup(env, "f")
    end

    test "function-form with empty body raises" do
      e = assert_raise Error, fn -> run("(define (f x))") end
      assert e.reason == {:bad_special_form, "define"}
    end

    test "redefining a name overwrites it" do
      assert run("(define x 1) (define x 2) x") == 2
    end
  end

  describe "begin" do
    test "returns the value of the last form" do
      assert run("(begin 1 2 3)") == 3
    end

    test "intermediate forms are evaluated for side effect" do
      assert run("(begin (define x 5) x)") == 5
    end

    test "empty begin returns :unspecified" do
      assert run("(begin)") == :unspecified
    end
  end

  describe "application" do
    test "primitive procedure" do
      env = Env.new() |> Env.define("inc", primitive_inc())
      assert Schooner.eval("(inc 41)", env) == 42
    end

    test "calling a non-procedure raises" do
      e = assert_raise Error, fn -> run("(5 1 2)") end
      assert match?({:not_a_procedure, 5}, e.reason)
    end

    test "primitive arity mismatch raises" do
      env = Env.new() |> Env.define("inc", primitive_inc())
      e = assert_raise Error, fn -> Schooner.eval("(inc 1 2)", env) end
      assert match?({:arity_mismatch, "inc", {:exact, 1}, 2}, e.reason)
    end

    test "improper application form raises :improper_application" do
      # Reader-level dotted application is rejected by the reader, so
      # synthesise the malformed form directly. `(+ 1 . 2)` reaches
      # eval_args/3 with a non-list tail and trips its catch-all.
      err =
        assert_raise Error, fn ->
          Schooner.Eval.eval(
            {:pair, {:sym, "+"}, {:pair, 1, 2}},
            base_env()
          )
        end

      assert err.reason == :improper_application
    end
  end

  describe "lexical scoping" do
    test "inner binding shadows outer" do
      assert run("""
             (define x 1)
             ((lambda (x) x) 99)
             """) == 99
    end

    test "outer binding is restored after inner scope" do
      assert run("""
             (define x 1)
             ((lambda (x) x) 99)
             x
             """) == 1
    end

    test "closure captures its defining environment, not the calling one" do
      assert run("""
             (define x 1)
             (define get-x (lambda () x))
             ((lambda (x) (get-x)) 99)
             """) == 1
    end

    test "nested lambdas access enclosing parameters" do
      assert run("(((lambda (x) (lambda (y) x)) 1) 2)") == 1
    end
  end

  describe "mutual recursion via top-level defines" do
    test "even?/odd? at small depth" do
      source = """
      (define (even? n)
        (if (zero-int? n) #t (odd? (sub1 n))))
      (define (odd? n)
        (if (zero-int? n) #f (even? (sub1 n))))
      """

      assert run_with_int_prims(source <> "(even? 10)") == Value.bool(true)
      assert run_with_int_prims(source <> "(odd? 10)") == Value.bool(false)
      assert run_with_int_prims(source <> "(even? 7)") == Value.bool(false)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp primitive_inc do
    Value.primitive("inc", 1, fn [n] when is_integer(n) -> n + 1 end)
  end

  defp run_with_int_prims(source) do
    env =
      Env.new()
      |> Env.define(
        "zero-int?",
        Value.primitive("zero-int?", 1, fn [n] -> Value.bool(n === 0) end)
      )
      |> Env.define("sub1", Value.primitive("sub1", 1, fn [n] -> n - 1 end))

    Schooner.eval(source, env)
  end
end

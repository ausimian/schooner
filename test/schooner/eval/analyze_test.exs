defmodule Schooner.Eval.AnalyzeTest do
  @moduledoc """
  The analyser front-loads shape checks that the evaluator used to
  perform on the fly. These tests pin the guarantee that doing so does
  not move *when* a malformed form fails: the error still surfaces
  only once evaluation reaches the offending node, after any earlier
  work has happened.

  Most of these shapes are rejected by the expander, so the forms are
  synthesised directly and fed to `Schooner.Eval.eval/2`.
  """

  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Eval.Analyze
  alias Schooner.Eval.Error
  alias Schooner.Eval.ExceptionState
  alias Schooner.Value

  defp sym(name), do: {:sym, name}

  # A primitive that records each call by messaging the test process,
  # so a test can tell whether evaluation reached a given point.
  defp env_with_probe do
    test_pid = self()

    Env.new()
    |> Env.define(
      "probe",
      Value.primitive("probe", 1, fn [tag] ->
        send(test_pid, {:probe, tag})
        tag
      end)
    )
  end

  defp probe(tag), do: [sym("probe"), tag]

  describe "analyze/1 never raises" do
    test "malformed forms become {:raise, exception} nodes" do
      assert {:raise, %Error{reason: {:bad_special_form, "quote"}}} =
               Analyze.analyze([sym("quote")])

      assert {:raise, %Error{reason: {:bad_special_form, "if"}}} = Analyze.analyze([sym("if")])
      assert {:raise, %Error{reason: :invalid_params}} = Analyze.analyze([sym("lambda"), 1, 1])
      assert {:raise, %Error{reason: :empty_application}} = Analyze.analyze([])
    end

    test "a malformed child does not poison its parent" do
      form = [sym("if"), false, [sym("quote")], 1]
      assert {:if, {:const, false}, {:raise, _}, {:const, 1}} = Analyze.analyze(form)
    end
  end

  describe "errors surface only when evaluation reaches the node" do
    test "a malformed form in an untaken if-branch is harmless" do
      form = [sym("if"), false, [sym("lambda"), 1, 1], 42]
      assert Eval.eval(form, Env.new()) == 42
    end

    test "a malformed lambda inside a closure body raises only when the closure runs" do
      inner_bad = [sym("lambda"), [sym("x")]]
      outer = [sym("lambda"), [], inner_bad]
      closure = Eval.eval(outer, Env.new())
      assert match?({:closure, _, _, _, _}, closure)

      e = assert_raise Error, fn -> Eval.apply_proc(closure, []) end
      assert e.reason == {:bad_special_form, "lambda"}
    end

    test "earlier forms in a begin run before a later malformed form raises" do
      env = env_with_probe()
      form = [sym("begin"), probe(1), [sym("quote")]]

      e = assert_raise Error, fn -> Eval.eval(form, env) end
      assert e.reason == {:bad_special_form, "quote"}
      assert_received {:probe, 1}
    end

    test "arguments before an improper tail are evaluated before :improper_application" do
      env = env_with_probe()
      form = [sym("probe") | [probe(1) | 2]]

      e = assert_raise Error, fn -> Eval.eval(form, env) end
      assert e.reason == :improper_application
      assert_received {:probe, 1}
    end

    test "letrec* inits run before a body desugar error raises" do
      env = env_with_probe()

      # (letrec* ((a (probe 1))) a (define b 2)) — a define after an
      # expression in the body.
      form = [
        sym("letrec*"),
        [[sym("a"), probe(1)]],
        sym("a"),
        [sym("define"), sym("b"), 2]
      ]

      e = assert_raise Error, fn -> Eval.eval(form, env) end
      assert e.reason == :define_after_expression
      assert_received {:probe, 1}
    end

    test "a malformed guard clause raises only if the clause walk reaches it" do
      env = env_with_probe()
      raise_form = [sym("raise"), 1]

      env =
        Env.define(
          env,
          "raise",
          Value.primitive("raise", 1, fn [v] -> ExceptionState.raise_value(v) end)
        )

      # First clause matches, so the malformed second clause is never inspected.
      ok = [sym("guard"), [sym("e"), [true, 10], :not_a_clause], raise_form]
      assert Eval.eval(ok, env) == 10

      # First clause declines, so the walk reaches the malformed one.
      bad = [sym("guard"), [sym("e"), [false, 10], :not_a_clause], raise_form]
      e = assert_raise Error, fn -> Eval.eval(bad, env) end
      assert e.reason == {:bad_special_form, "guard"}
    end
  end

  describe "compiled programs" do
    test "a runtime error in a compiled program still fires at run time" do
      compiled = Schooner.compile!("(define (f) (car 1)) 'ok")
      assert Schooner.run_compiled!(compiled, Schooner.Environment.new()) == Value.symbol("ok")
    end
  end

  describe "quasiquote templates" do
    test "constant templates fold, unquoted spines rebuild" do
      assert Schooner.run!("`(1 (2 3) #(4 5))") ==
               Value.list([1, Value.list([2, 3]), Value.vector([4, 5])])

      assert Schooner.run!("(let ((x 9)) `(1 ,x #(a ,x) ,@(list x x)))") ==
               Value.list([1, 9, Value.vector([Value.symbol("a"), 9]), 9, 9])
    end

    test "nested quasiquote keeps inner unquotes literal" do
      assert Schooner.run!("(let ((x 1)) `(a `(b ,(c ,x))))") ==
               Schooner.run!("'(a (quasiquote (b (unquote (c 1)))))")
    end
  end
end

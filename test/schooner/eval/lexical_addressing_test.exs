defmodule Schooner.Eval.LexicalAddressingTest do
  @moduledoc """
  The analyser resolves every variable reference to a lexical slot or a
  global at analysis time. These tests pin the resolution shapes and
  the corner cases where the old by-name walk had behaviour that a
  naive slot lookup would lose: released `letrec` frames, duplicate
  parameter names, and hygiene-marked free references.
  """

  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Eval.Analyze
  alias Schooner.Eval.Error
  alias Schooner.Value

  defp sym(name), do: {:sym, name}

  # Same encoding the expander uses for a hygiene-marked name.
  defp marked(name, mark), do: name <> <<0>> <> Integer.to_string(mark)

  describe "resolution shapes" do
    test "parameters resolve to {depth, slot}; free names to globals" do
      # (lambda (x) (lambda (y) (x y z)))
      form = [
        sym("lambda"),
        [sym("x")],
        [sym("lambda"), [sym("y")], [sym("x"), sym("y"), sym("z")]]
      ]

      assert {:lambda, _, {{"x"}, [inner]}, nil} = Analyze.analyze(form)
      assert {:lambda, _, {{"y"}, [app]}, nil} = inner
      assert {:app, {:lref, 1, 1}, [{:lref, 0, 1}, {:gref, "z", nil}]} = app
    end

    test "letrec* names resolve to rec slots with a by-name fallback below the frame" do
      # (lambda (f) (letrec* ((f 1) (g f)) g))
      form = [
        sym("lambda"),
        [sym("f")],
        [sym("letrec*"), [[sym("f"), 1], [sym("g"), sym("f")]], sym("g")]
      ]

      assert {:lambda, _, {_, [letrec]}, nil} = Analyze.analyze(form)
      assert {:letrec, ["f", "g"], [{:single, 0, _}, {:single, 1, f_ref}], [g_ref]} = letrec
      assert f_ref == {:rref, 0, 0, "f", {:lref, 1, 1}}
      assert g_ref == {:rref, 0, 1, "g", {:gref, "g", nil}}
    end

    test "a marked free name carries its unmarked base as a fallback" do
      name = marked("car", 7)
      assert {:gref, ^name, {:gref, "car", nil}} = Analyze.analyze(sym(name))

      # The base is resolved lexically when it is in scope.
      form = [sym("lambda"), [sym("car")], sym(name)]
      assert {:lambda, _, {_, [{:gref, ^name, {:lref, 0, 1}}]}, _} = Analyze.analyze(form)
    end
  end

  describe "run-time behaviour" do
    test "a duplicated parameter name binds the last argument" do
      form = [sym("lambda"), [sym("x"), sym("x")], sym("x")]
      closure = Eval.eval(form, Env.new())
      assert Eval.apply_proc(closure, [1, 2]) == 2
    end

    test "a marked free name falls back to its unmarked base" do
      env = Env.define(Env.new(), "base", 42)
      assert Eval.eval(sym(marked("base", 3)), env) == 42
    end

    test "a marked name that is bound globally wins over its base" do
      env = Env.new() |> Env.define("v", :base) |> Env.define(marked("v", 1), :marked)
      assert Eval.eval(sym(marked("v", 1)), env) == :marked
    end

    test "an unresolvable marked name reports the marked name as unbound" do
      name = marked("nowhere", 2)
      e = assert_raise Error, fn -> Eval.eval(sym(name), Env.new()) end
      assert e.reason == {:unbound, name}
    end
  end

  describe "released letrec frames" do
    # A host primitive smuggles a closure out of a letrec whose body
    # returns a plain number, so the frame is released while the
    # closure is still reachable. Looking a letrec name up through the
    # dead frame continues to the enclosing scope, as the by-name walk
    # did.
    defp run_and_call_stashed(source) do
      pid = self()

      env =
        Schooner.Environment.new(
          pre_imports: [["scheme", "base"]],
          libraries: [
            Schooner.Host.library(
              primitives: [{"stash", 1, fn [c] -> send(pid, {:stashed, c}) && 0 end}]
            )
          ]
        )

      Schooner.eval!(source, env)
      assert_received {:stashed, closure}
      Schooner.apply(closure, [])
    end

    test "falls through to a global of the same name" do
      assert run_and_call_stashed("""
             (define f 'global-f)
             (letrec ((f (lambda () 'inner)) (h (lambda () f))) (stash h) 1)
             """) == {:ok, Value.symbol("global-f")}
    end

    test "falls through to an enclosing parameter of the same name" do
      assert run_and_call_stashed("""
             ((lambda (f)
                (letrec ((f (lambda () 'inner)) (h (lambda () f))) (stash h) 1))
              'outer-param)
             """) == {:ok, Value.symbol("outer-param")}
    end

    test "is unbound when nothing else binds the name" do
      assert {:error, %Error{reason: {:unbound, "only-here"}}} =
               run_and_call_stashed("""
               (letrec ((only-here (lambda () 'inner)) (h (lambda () only-here)))
                 (stash h)
                 1)
               """)
    end
  end
end

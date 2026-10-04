defmodule Schooner.SessionTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Host
  alias Schooner.Library.Loader
  alias Schooner.Location
  alias Schooner.Session

  doctest Schooner.Session

  defp base, do: Session.new(Environment.new(pre_imports: [["scheme", "base"]]))

  # An environment whose registry has a library `(macros)` that
  # exports the macro `twice`.
  defp macro_library_env do
    registry =
      Loader.load_string("""
      (define-library (macros)
        (export twice)
        (import (scheme base))
        (begin (define-syntax twice (syntax-rules () ((_ e) (+ e e))))))
      """)

    Environment.new(libraries: [registry[["macros"]]], pre_imports: [["scheme", "base"]])
  end

  # Evaluate each source in turn, failing on an error, and return the
  # session.
  defp eval!(session, sources) do
    Enum.reduce(sources, session, fn source, session ->
      {:ok, _value, session} = Session.eval(session, source)
      session
    end)
  end

  describe "state persists across eval/3" do
    test "definitions" do
      session = eval!(base(), ["(define x 41)", "(define (inc n) (+ n 1))"])
      assert {:ok, 42, _} = Session.eval(session, "(inc x)")
    end

    test "variables an import binds" do
      session = eval!(Session.new(Environment.new()), ["(import (only (scheme base) car))"])
      assert {:ok, 1, _} = Session.eval(session, "(car '(1 2))")
    end

    test "macros an import binds" do
      session = eval!(Session.new(macro_library_env()), ["(import (macros))"])
      assert {:ok, 2, _} = Session.eval(session, "(twice 1)")
    end

    test "define-syntax macros" do
      session = eval!(base(), ["(define-syntax swap (syntax-rules () ((_ a b) (list b a))))"])
      assert {:ok, [2, 1], _} = Session.eval(session, "(swap 1 2)")
    end

    test "a macro defined in a top-level begin" do
      session = eval!(base(), ["(begin (define-syntax one (syntax-rules () ((_) 1))))"])
      assert {:ok, 1, _} = Session.eval(session, "(one)")
    end

    test "a later define-syntax replaces an earlier one" do
      session =
        eval!(base(), [
          "(define-syntax m (syntax-rules () ((_) 1)))",
          "(define-syntax m (syntax-rules () ((_) 2)))"
        ])

      assert {:ok, 2, _} = Session.eval(session, "(m)")
    end

    test "a later import shadows an earlier one" do
      session =
        eval!(Session.new(Environment.new()), [
          "(import (prefix (scheme base) b:))",
          "(import (rename (only (scheme base) car) (car first)))"
        ])

      assert {:ok, 1, _} = Session.eval(session, "(first (b:list 1 2))")
    end

    test "Schooner.eval/3 alone keeps definitions but not imported macros" do
      environment = macro_library_env()
      {:ok, _} = Schooner.eval("(import (macros)) (define x 1)", environment)

      assert {:ok, 1} = Schooner.eval("x", environment)

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "twice"}}} =
               Schooner.eval("(twice 1)", environment)
    end
  end

  describe "errors" do
    test "leave the session usable" do
      session = eval!(base(), ["(define x 1)"])

      assert {:error, %Schooner.Primitive.Error{}, session} = Session.eval(session, "(car x)")
      assert {:error, %Schooner.Reader.Error{}, session} = Session.eval(session, "(+ 1")
      assert {:error, %Schooner.Eval.Error{}, session} = Session.eval(session, "(nope)")
      assert {:error, %Schooner.Error{}, session} = Session.eval(session, "(raise 'boom)")
      assert {:ok, 2, _} = Session.eval(session, "(+ x 1)")
    end

    test "keep the definitions evaluated before them" do
      {:error, _, session} = Session.eval(base(), "(define a 1) (car a) (define b 2)")

      assert {:ok, 1, session} = Session.eval(session, "a")

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "b"}}, _} =
               Session.eval(session, "b")
    end

    test "at run time keep the source's macros" do
      {:error, _, session} =
        Session.eval(base(), "(define-syntax one (syntax-rules () ((_) 1))) (car 1)")

      assert {:ok, 1, _} = Session.eval(session, "(one)")
    end

    test "in expansion keep the source's imports" do
      {:error, %Schooner.Eval.Error{}, session} =
        Session.eval(Session.new(Environment.new()), "(import (scheme base)) (if)")

      assert {:ok, 1, _} = Session.eval(session, "(when #t 1)")
    end

    test "in reading or importing change nothing" do
      session = Session.new(Environment.new())

      assert {:error, %Schooner.Reader.Error{}, session} =
               Session.eval(session, "(import (scheme base)) (")

      assert {:error, %Schooner.Library.NotFoundError{}, session} =
               Session.eval(session, "(import (scheme base) (no such))")

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "car"}}, _} =
               Session.eval(session, "(car '(1))")
    end

    test "are located in the source" do
      assert {:error, e, _} = Session.eval(base(), "(define x 1)\n(car y)")
      assert e.location == %Location{file: nil, line: 2, column: 6}
    end

    test ":file names the source" do
      assert {:error, e, _} = Session.eval(base(), "(car y)", file: "s.scm")
      assert e.location == %Location{file: "s.scm", line: 1, column: 6}
      assert Exception.message(e) == "s.scm:1:6: unbound variable: y"
    end

    test "carry a backtrace with debug: true" do
      session = Session.new(Environment.new(pre_imports: [["scheme", "base"]]), debug: true)
      {:ok, _, session} = Session.eval(session, "(define (f x) (car x))")

      assert {:error, e, _} = Session.eval(session, "(f 1)")
      assert e.location == %Location{file: nil, line: 1, column: 15}
      assert [%{name: "car"}, %{name: "f"}] = e.scheme_backtrace
    end

    test "carry no backtrace by default" do
      {:error, e, _} = Session.eval(base(), "(car 1)")
      assert e.scheme_backtrace == nil
    end

    test "that aren't script errors are raised" do
      environment =
        Environment.new(
          libraries: [
            Host.library(name: [], primitives: [{"crash", 0, fn [] -> raise "boom" end}])
          ]
        )

      assert_raise RuntimeError, "boom", fn ->
        Session.eval(Session.new(environment), "(crash)")
      end
    end
  end

  describe "the environment's surface" do
    test "a primitive the environment doesn't expose is unbound, as with Schooner.eval/3" do
      environment =
        Environment.new(standard_libraries: [:base], pre_imports: [["scheme", "base"]])

      source = "(char-upcase #\\a)"

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "char-upcase"}}} =
               Schooner.eval(source, environment)

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "char-upcase"}}, _} =
               Session.eval(Session.new(environment), source)
    end

    test "a library missing from the registry can't be imported" do
      environment = Environment.new(standard_libraries: [:base])

      assert {:error, %Schooner.Library.NotFoundError{}, _} =
               Session.eval(Session.new(environment), "(import (scheme char))")
    end
  end

  describe "bindings/1" do
    test "lists variables and macros with the library that exports them" do
      environment =
        Environment.new(
          standard_libraries: [:base],
          pre_imports: [["scheme", "base"]],
          libraries: [
            Host.library(name: ["app"], primitives: [{"price", 1, fn [_] -> 1 end}]),
            Host.library(name: [], primitives: [{"anon", 0, fn [] -> 1 end}])
          ]
        )

      session =
        eval!(Session.new(environment), [
          "(import (app))",
          "(define x 1)",
          "(define-syntax m (syntax-rules () ((_) 1)))"
        ])

      bindings = Map.new(Session.bindings(session), &{&1.name, &1})

      assert %{kind: :procedure, library: ["scheme", "base"]} = bindings["car"]
      assert %{kind: :procedure, library: ["app"]} = bindings["price"]
      assert %{kind: :procedure, library: nil} = bindings["anon"]
      assert %{kind: :value, library: nil, value: 1} = bindings["x"]
      assert %{kind: :macro, library: nil, value: nil} = bindings["m"]
      assert %{kind: :macro, library: ["scheme", "base"]} = bindings["when"]
    end

    test "are sorted by name" do
      names = base() |> Session.bindings() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
    end

    test "a name bound as both is listed as the macro, which a use of it expands to" do
      session =
        eval!(base(), [
          "(define f 42)",
          "(define-syntax f (syntax-rules () ((_) 1)))",
          "(define when 1)"
        ])

      assert {:ok, 1, _} = Session.eval(session, "(f)")
      assert {:ok, 2, _} = Session.eval(session, "(when #t 2)")

      kinds =
        for %{name: name, kind: kind} <- Session.bindings(session),
            name in ["f", "when"],
            do: kind

      assert kinds == [:macro, :macro]
    end
  end

  test "environment/1 expands with the session's macros" do
    session = eval!(base(), ["(define-syntax twice (syntax-rules () ((_ e) (begin e e))))"])

    assert {:ok, [form]} = Schooner.expand("(twice (f))", Session.environment(session))
    assert Schooner.Pretty.format(form) == "(begin (f) (f))"
  end

  test "new/2 rejects unknown options" do
    assert_raise ArgumentError, fn -> Session.new(Environment.new(), nope: true) end
  end
end

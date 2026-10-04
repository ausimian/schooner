defmodule Schooner.SourceLocationTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Library
  alias Schooner.Library.Loader
  alias Schooner.Location

  defp env, do: Environment.new(pre_imports: [["scheme", "base"]])

  defp error!(source, opts \\ []) do
    assert {:error, e} = Schooner.eval(source, env(), [file: "t.scm"] ++ opts)
    e
  end

  defp at(e), do: e.location && {e.location.file, e.location.line, e.location.column}

  describe "locations of errors found before the script runs" do
    test "an unbound variable is placed at the reference" do
      e = error!("(define (f x)\n  (+ x y))\n(f 1)")
      assert %Schooner.Eval.Error{reason: {:unbound, "y"}} = e
      assert at(e) == {"t.scm", 2, 8}
      assert e.message == "t.scm:2:8: unbound variable: y"
    end

    test "an unbound operator of an inlined arithmetic call is placed at the call" do
      assert {:error, e} = Schooner.eval("\n  (+ 1 2)", Schooner.Env.new(), file: "t.scm")
      assert at(e) == {"t.scm", 2, 3}
    end

    test "a malformed special form is placed at the form" do
      e = error!("(define x 1)\n (if)")
      assert %Schooner.Eval.Error{reason: {:bad_special_form, "if"}} = e
      assert at(e) == {"t.scm", 2, 2}
    end

    test "an analysis error in an untaken branch still fails only when reached" do
      src = "(if #t 1 ((lambda () 1 (define y 2) y)))"
      assert {:ok, 1} = Schooner.eval(src, env(), file: "t.scm")
    end

    test "a definition after an expression in a body is placed at the definition" do
      e = error!("(define (f)\n  1\n  (define y 2) y)")
      assert e.reason == :define_after_expression
      assert at(e) == {"t.scm", 3, 3}
    end

    test "a reader error carries the file" do
      e = error!("(define x 1)\n  (car")
      assert %Schooner.Reader.Error{reason: :unterminated_list, position: {2, 3}} = e
      assert at(e) == {"t.scm", 2, 3}
      assert e.message == "t.scm:2:3: unterminated list"
    end

    test "a lexer error carries the file" do
      e = error!("\n #\\bogus")
      assert %Schooner.Lexer.Error{} = e
      assert at(e) == {"t.scm", 2, 2}
    end

    test "an import of a missing library is placed at its spec" do
      e = error!("(import (scheme base)\n        (no such))\n1")
      assert %Library.NotFoundError{} = e
      assert at(e) == {"t.scm", 2, 9}
      assert Exception.message(e) == "t.scm:2:9: library not found: (no such)"
    end

    test "a letrec binding read before its init is placed at the reference" do
      e = error!("(letrec ((a (lambda () b))\n         (b (a)))\n  b)")
      assert e.reason == {:rec_uninitialised, "b"}
      assert at(e) == {"t.scm", 1, 24}
    end

    test "with locations but no file the location has no file and the message no prefix" do
      assert {:error, e} = Schooner.eval("\n  zz", env(), locations: true)
      assert e.location == %Location{file: nil, line: 2, column: 3}
      assert e.message == "unbound variable: zz"
    end

    test "are not recorded unless asked for" do
      assert {:error, e} = Schooner.eval("\n  zz", env())
      assert e.location == nil

      assert {:error, e} = Schooner.eval("\n  zz", env(), file: "t.scm", locations: false)
      assert e.location == nil
      assert e.message == "unbound variable: zz"

      assert {:ok, compiled} = Schooner.compile("\n  zz", env())
      assert {:error, %{location: nil}} = Schooner.run_compiled(compiled, env())
    end

    test "lexer and reader errors keep their position but no location when not asked for" do
      assert {:error, %Schooner.Reader.Error{position: {1, 1}, location: nil}} =
               Schooner.eval("(", env())

      assert {:error, %Schooner.Lexer.Error{location: nil}} = Schooner.eval("#\\bogus", env())
    end

    test "debug turns locations on" do
      assert {:error, e} = Schooner.eval("\n  zz", env(), debug: true)
      assert e.location == %Location{file: nil, line: 2, column: 3}
    end
  end

  describe "locations of errors raised while applying a procedure" do
    test "are not recorded without debug" do
      e = error!("(define (f x)\n  (+ x \"a\"))\n(f 1)")
      assert %Schooner.Primitive.Error{location: nil} = e
      assert e.message == "type error in `+`: expected number, got \"a\""
    end

    test "a primitive type error is placed at the call" do
      e = error!("(define (f x)\n  (+ x \"a\"))\n(f 1)", debug: true)
      assert %Schooner.Primitive.Error{reason: {:type_error, "+", _, _}} = e
      assert at(e) == {"t.scm", 2, 3}
      assert e.message == "t.scm:2:3: type error in `+`: expected number, got \"a\""
    end

    test "an arity mismatch is placed at the call" do
      e = error!("(define (f x) x)\n\n  (f 1 2)", debug: true)
      assert e.reason == {:arity_mismatch, "f", {:exact, 1}, 2}
      assert at(e) == {"t.scm", 3, 3}
    end

    test "an arity mismatch of a variadic closure is placed at the call" do
      e = error!("(define (f x . r) x)\n(f)", debug: true)
      assert e.reason == {:arity_mismatch, "f", {:at_least, 1}, 0}
      assert at(e) == {"t.scm", 2, 1}
    end

    test "a primitive arity mismatch is placed at the call" do
      e = error!("(car)", debug: true)
      assert e.reason == {:arity_mismatch, "car", {:exact, 1}, 0}
      assert at(e) == {"t.scm", 1, 1}
    end

    test "applying a non-procedure is placed at the call" do
      e = error!("(define x 1)\n(x 2)", debug: true)
      assert e.reason == {:not_a_procedure, 1}
      assert at(e) == {"t.scm", 2, 1}
    end

    test "an uncaught (error ...) is placed at the call" do
      e = error!("(define (g)\n   (error \"boom\" 1))\n(g)", debug: true)
      assert %Schooner.Error{} = e
      assert at(e) == {"t.scm", 2, 4}
      assert e.message == "t.scm:2:4: uncaught Scheme error: boom: 1"
    end

    test "an error a guard does not handle keeps its location" do
      e = error!("(guard (e (#f 1))\n  (vector-ref (vector) 3))", debug: true)
      assert at(e) == {"t.scm", 2, 3}
    end

    test "an error a guard catches but does not handle keeps the raise site" do
      e = error!("(guard (e (#f 1))\n  (error \"x\"))", debug: true)
      assert %Schooner.Error{} = e
      assert at(e) == {"t.scm", 2, 3}

      src = "(guard (e (#f 1))\n  (raise 5))"
      {:ok, compiled} = Schooner.compile(src, env(), file: "t.scm", debug: true)
      assert {:error, e} = Schooner.run_compiled(compiled, env())
      assert e.value == 5
      assert at(e) == {"t.scm", 2, 3}
    end

    test "a guard that handles a raise still returns its value" do
      assert {:ok, 42} =
               Schooner.eval("(guard (e (#t (+ e 1))) (raise 41))", env(), debug: true)
    end

    test "applying a guard => clause's procedure is placed at the clause" do
      e = error!("(guard (e\n  (#t => 1))\n  (raise 2))", debug: true)
      assert e.reason == {:not_a_procedure, 1}
      assert at(e) == {"t.scm", 2, 3}
    end

    test "an error in a callback is placed in the callback, not at map" do
      e = error!("(map (lambda (x)\n  (car x)) '(1))", debug: true)
      assert at(e) == {"t.scm", 2, 3}
    end

    test "a host conversion error is placed at the call" do
      lib =
        Schooner.Host.library(
          name: [],
          primitives: [
            {"host-len", 1,
             fn [s] -> String.length(Schooner.Host.to_string!(s, op: "host-len")) end}
          ]
        )

      environment = Environment.new(pre_imports: [["scheme", "base"]], libraries: [lib])

      e =
        assert_raise Schooner.Host.TypeError, fn ->
          Schooner.eval!("\n(host-len 1)", environment, file: "t.scm", debug: true)
        end

      assert at(e) == {"t.scm", 2, 1}
    end
  end

  describe "macro expansion" do
    test "an error in a cond clause is placed at the user's form" do
      src = "(define (h x)\n  (cond ((> x 0)\n         (car x))\n        (else 0)))\n(h 5)"
      assert at(error!(src, debug: true)) == {"t.scm", 3, 10}
    end

    test "an unbound name in a let body is placed at the name" do
      assert at(error!("(let ((a 1))\n  (+ a\n     zz))")) == {"t.scm", 3, 6}
    end

    test "a form a macro introduces takes the macro use's position" do
      # `(when)` matches no rule of the `when` macro in base.scm.
      e = error!("(define x 1)\n  (when)")
      assert %Schooner.Eval.Error{reason: {:bad_special_form, "when"}} = e
      assert at(e) == {"t.scm", 2, 3}
    end

    test "a user-defined macro's template error is placed at its use" do
      src = """
      (define-syntax bad
        (syntax-rules () ((_ e) (if))))
      (define y 2)
        (bad y)
      """

      assert at(error!(src)) == {"t.scm", 4, 3}
    end

    test "an error inside a record accessor is placed at the record definition" do
      src = "(define-record-type point (make-point x) point? (x point-x))\n  (point-x 5)"
      assert at(error!(src, debug: true)) == {"t.scm", 1, 1}
    end
  end

  describe "compiled programs" do
    test "keep locations through compile/3 and run_compiled/2" do
      src = "(define (f x)\n  (car x))\n(f 1)"
      {:ok, compiled} = Schooner.compile(src, env(), file: "c.scm", debug: true)
      assert {:error, e} = Schooner.run_compiled(compiled, env())
      assert at(e) == {"c.scm", 2, 3}
    end

    test "are plain data that round-trips through term_to_binary" do
      {:ok, compiled} = Schooner.compile("(define (f)\n  zz)\n(f)", env(), file: "c.scm")
      copy = compiled |> :erlang.term_to_binary() |> :erlang.binary_to_term()
      assert copy == compiled
      assert {:error, e} = Schooner.run_compiled(copy, env())
      assert at(e) == {"c.scm", 2, 3}
    end

    test "carry analysis errors with their location" do
      src = "1\n ((lambda () 1 (define y 2) y))"
      {:ok, compiled} = Schooner.compile(src, env(), file: "c.scm")
      assert {:error, e} = Schooner.run_compiled(compiled, env())
      assert e.reason == :define_after_expression
      assert at(e) == {"c.scm", 2, 16}
    end
  end

  describe "libraries loaded from files" do
    @tag :tmp_dir
    test "an error in a library procedure is placed in the library file", %{tmp_dir: dir} do
      path = Path.join(dir, "lib.scm")

      File.write!(path, """
      (define-library (pricing)
        (import (scheme base))
        (export price total)
        (begin
          (define (price sku)
            (car sku))
          (define (total)
            missing)))
      """)

      environment = library_env(Loader.load_file(path, Library.standard(), debug: true))

      assert {:error, e} =
               Schooner.eval("(import (scheme base) (pricing))\n(price 1)", environment,
                 file: "s.scm",
                 debug: true
               )

      assert at(e) == {path, 6, 7}

      assert {:error, e} =
               Schooner.eval("(import (scheme base) (pricing))\n(total)", environment,
                 file: "s.scm"
               )

      assert at(e) == {path, 8, 7}
    end

    @tag :tmp_dir
    test "a form from an included file is placed in that file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "body.scm"), "\n(define (oops) nope)\n")

      File.write!(Path.join(dir, "lib.scm"), """
      (define-library (inc)
        (import (scheme base))
        (export oops)
        (include "body.scm"))
      """)

      environment = library_env(Loader.load_file(Path.join(dir, "lib.scm"), Library.standard()))

      assert {:error, e} = Schooner.eval("(import (inc))\n(oops)", environment)
      assert at(e) == {Path.join(dir, "body.scm"), 2, 16}
    end

    defp library_env(registry) do
      libs = for {name, lib} <- registry, name in [["pricing"], ["inc"]], do: lib
      Environment.new(libraries: libs)
    end
  end

  describe "format_error/2" do
    test "renders the message with a caret under the failing column" do
      source = "(define (f x)\n  (+ x \"a\"))\n(f 1)"
      e = error!(source, debug: true)

      assert Schooner.format_error(e, source: source) == """
             t.scm:2:3: type error in `+`: expected number, got "a"
               |
             2 |   (+ x "a"))
               |   ^

             Scheme backtrace (most recent first):
               +  t.scm:2:3 (tail call)
               f  t.scm:3:1\
             """
    end

    test "widens the gutter for longer line numbers and keeps tabs" do
      source = String.duplicate("\n", 11) <> "\t(car 1)"
      e = error!(source, debug: true)

      assert Schooner.format_error(e, source: source) ==
               "t.scm:12:2: type error in `car`: expected pair, got 1\n" <>
                 "   |\n" <>
                 "12 | \t(car 1)\n" <>
                 "   | \t^\n\n" <>
                 "Scheme backtrace (most recent first):\n" <>
                 "  car  t.scm:12:2"
    end

    test "places the caret by codepoint column under combining characters" do
      source = "\"e\u0301\" zz"
      {:error, e} = Schooner.eval(source, env(), locations: true)
      assert e.location.column == 6

      assert Schooner.format_error(e, source: source) ==
               "1:6: unbound variable: zz\n  |\n1 | #{source}\n  |     ^"
    end

    test "prefixes line:col when there is no file" do
      {:error, e} = Schooner.eval("\n zz", env(), locations: true)
      assert Schooner.format_error(e) == "2:2: unbound variable: zz"
    end

    test "returns the bare message without a location" do
      e = error!("(car 1)")
      assert e.location == nil

      assert Schooner.format_error(e, source: "(car 1)") ==
               "type error in `car`: expected pair, got 1"
    end

    test "returns the header alone when the line is not in the source" do
      e = error!("\n\n zz")
      assert Schooner.format_error(e, source: "") == "t.scm:3:2: unbound variable: zz"
    end
  end

  describe "guides/tooling.md" do
    # The guide's running example: the pricing script, run against an
    # environment like `MyApp.Scripts.environment/0`, must produce the
    # location and rendering the "Source locations in errors" section
    # shows.
    @guide File.read!("guides/tooling.md")

    test "the source-location example matches the guide" do
      [_, script] =
        Regex.run(~r/and one script, `scripts\/pricing.scm`:\n\n```scheme\n(.*?)```/s, @guide)

      [section] = Regex.run(~r/## Source locations in errors.*?(?=\n## |\z)/s, @guide)
      [_, rendered] = Regex.run(~r/```text\n(.*?)\n```/s, section)

      environment =
        Environment.new(
          standard_libraries: [:base, :char, :write],
          pre_imports: [["scheme", "base"]],
          libraries: [
            Schooner.Host.library(
              name: ["myapp", "catalog"],
              primitives: [{"unit-price", 1, fn [_sku] -> 10 end}]
            )
          ]
        )

      assert {:error, error} =
               Schooner.eval(script <> ~s|(order-total '(("widget" . "3")))|, environment,
                 file: "scripts/pricing.scm",
                 debug: true
               )

      assert error.location == %Location{file: "scripts/pricing.scm", line: 4, column: 3}
      assert Schooner.format_error(error, source: script) == rendered
    end
  end

  describe "options" do
    test "eval/3 with an Environment rejects :implicit_imports" do
      assert_raise ArgumentError, ~r/implicit_imports/, fn ->
        Schooner.eval("1", env(), implicit_imports: :all)
      end
    end
  end

  describe "tail calls" do
    # Positions are captured when closures are built, so neither mode
    # may add a frame per iteration.
    for debug <- [false, true] do
      test "a 1M-iteration tail loop runs in bounded memory (debug: #{debug})" do
        assert_bounded(fn ->
          Schooner.eval!(
            "(define (loop n) (if (= n 0) 'done (loop (- n 1)))) (loop 1000000)",
            env(),
            debug: unquote(debug)
          )
        end)
      end

      test "a tail loop through apply runs in bounded memory (debug: #{debug})" do
        assert_bounded(fn ->
          Schooner.eval!(
            "(define (loop n) (if (= n 0) 'done (apply loop (list (- n 1))))) (loop 300000)",
            env(),
            debug: unquote(debug)
          )
        end)
      end

      test "a tail loop through call-with-values runs in bounded memory (debug: #{debug})" do
        assert_bounded(fn ->
          Schooner.eval!(
            """
            (define (loop n)
              (if (= n 0) 'done (call-with-values (lambda () (- n 1)) loop)))
            (loop 300000)
            """,
            env(),
            debug: unquote(debug)
          )
        end)
      end
    end

    defp assert_bounded(fun) do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false})
          send(parent, {:result, self(), fun.()})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000
      assert_received {:result, ^pid, {:sym, "done"}}
    end
  end
end

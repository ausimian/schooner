defmodule Schooner.CheckTest do
  use ExUnit.Case, async: true

  alias Schooner.Diagnostic
  alias Schooner.Environment
  alias Schooner.Host
  alias Schooner.Location

  doctest Schooner.Diagnostic

  defp env, do: Environment.new(pre_imports: [["scheme", "base"]])

  defp check(source, environment \\ env()), do: Schooner.check(source, environment, file: "t.scm")

  defp summary(diagnostics) do
    Enum.map(diagnostics, fn %Diagnostic{location: loc} = d ->
      {d.severity, d.code, loc && {loc.file, loc.line, loc.column}}
    end)
  end

  describe "never evaluates" do
    setup do
      test_pid = self()

      environment =
        Environment.new(
          pre_imports: [["scheme", "base"]],
          libraries: [
            Host.library(
              name: [],
              primitives: [{"notify", 1, fn [x] -> send(test_pid, {:notified, x}) && x end}]
            )
          ]
        )

      %{environment: environment}
    end

    test "a script that would raise", %{environment: environment} do
      assert check("(raise 'boom)\n(error \"failed\" 1)\n(car 1)", environment) == []
    end

    test "a script that would loop forever", %{environment: environment} do
      assert check("(define (spin n) (spin (+ n 1)))\n(spin 0)", environment) == []
    end

    test "a script that calls a host primitive", %{environment: environment} do
      assert check("(notify 1)\n(define x (notify 2))\n(notify x)", environment) == []
      refute_received {:notified, _}
    end

    test "only reports diagnostics for a failing script", %{environment: environment} do
      assert [%Diagnostic{code: :unbound}] = check("(notify 1)\n(notfy 2)", environment)
      refute_received {:notified, _}
    end

    test "leaves the environment unchanged", %{environment: environment} do
      assert check("(import (scheme char))\n(define y 1)", environment) == []

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "y"}}} =
               Schooner.eval("y", environment)

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "char-upcase"}}} =
               Schooner.eval("char-upcase", environment)
    end
  end

  describe "diagnostic codes" do
    test ":read_error at the failing position, and nothing else" do
      assert [d] = check("(define x 1)\n(car (cdr x)")
      assert d.code == :read_error
      assert d.message == "unterminated list"
      assert summary([d]) == [{:error, :read_error, {"t.scm", 2, 1}}]
    end

    test ":read_error from the lexer" do
      assert [%Diagnostic{code: :read_error, location: %Location{line: 1, column: 1}}] =
               check("#\\nosuchchar")
    end

    test ":syntax_error for a malformed core form" do
      assert [d] = check("(define x 1)\n  (if)")
      assert d.message == "malformed `if` form"
      assert summary([d]) == [{:error, :syntax_error, {"t.scm", 2, 3}}]
    end

    test ":syntax_error for a malformed macro use" do
      assert summary(check("(let ((x)) x)")) == [{:error, :syntax_error, {"t.scm", 1, 1}}]
    end

    test ":syntax_error for analysis errors, which eval only raises when reached" do
      source = "(if #t 1 ((lambda () 1 (define y 2) y)))"
      assert {:ok, 1} = Schooner.eval(source, env())

      assert [d] = check(source)
      assert d.message == "internal `define` after a non-definition expression"
      assert summary([d]) == [{:error, :syntax_error, {"t.scm", 1, 24}}]
    end

    test ":syntax_error for a malformed guard clause" do
      assert summary(check("(guard (e 1) 2)")) == [{:error, :syntax_error, {"t.scm", 1, 1}}]
    end

    test ":syntax_error for a malformed import set" do
      assert [d] = check("(import (only (scheme char) 1))")
      assert d.message == "malformed `import` form"
      assert summary([d]) == [{:error, :syntax_error, {"t.scm", 1, 9}}]
    end

    test "each malformed top-level form is reported, and the others are still checked" do
      assert summary(check("(if)\n(define (f) (when))\n(car 1 2)\n(f)")) == [
               {:error, :syntax_error, {"t.scm", 1, 1}},
               {:error, :syntax_error, {"t.scm", 2, 13}},
               {:error, :arity, {"t.scm", 3, 1}}
             ]
    end

    test ":unknown_library at the import spec" do
      assert [d] = check("(import (scheme char)\n        (myapp promos))")
      assert d.message == "library not found: (myapp promos)"
      assert summary([d]) == [{:error, :unknown_library, {"t.scm", 2, 9}}]
    end

    test ":unbound at the reference" do
      assert [d] = check("(define (f x)\n  (+ x y))")
      assert d.message == "unbound variable: y"
      assert summary([d]) == [{:error, :unbound, {"t.scm", 2, 8}}]
    end

    test ":unbound for an identifier an import set does not export" do
      assert [d] = check("(import (only (scheme char) char-upcse))")
      assert d.code == :unbound
      assert d.message =~ "identifier `char-upcse` is not exported"
      assert summary([d]) == [{:error, :unbound, {"t.scm", 1, 9}}]
    end

    test ":unbound in code that would never run" do
      assert summary(check("(define (never) (missing))")) == [
               {:error, :unbound, {"t.scm", 1, 18}}
             ]
    end

    test ":unbound is not reported when an import fails" do
      assert [%Diagnostic{code: :unknown_library}] =
               check("(import (myapp promos))\n(discount 1)")
    end

    test ":arity against a primitive" do
      assert [d] = check("(define p '(1))\n(car p p)")
      assert d.message == "arity mismatch in `car`: expected 1, got 2"
      assert summary([d]) == [{:error, :arity, {"t.scm", 2, 1}}]
    end

    test ":arity against a primitive with a range of arities" do
      assert [d] = check("(make-vector)")
      assert d.message == "arity mismatch in `make-vector`: expected between 1 and 2, got 0"
    end

    test ":arity against a top-level lambda" do
      assert summary(check("(define (f a b) a)\n(f 1)\n(define g (lambda (a . r) a))\n(g)")) ==
               [{:error, :arity, {"t.scm", 2, 1}}, {:error, :arity, {"t.scm", 4, 1}}]
    end

    test ":arity against the procedure of a guard => clause" do
      assert [d] = check("(guard (e (#t => cons)) (raise 1))")
      assert d.message == "arity mismatch in `cons`: expected 2, got 1"
      assert summary([d]) == [{:error, :arity, {"t.scm", 1, 11}}]
      assert check("(guard (e (#t => list)) (raise 1))") == []
    end

    test ":arity against a host primitive" do
      environment =
        Environment.new(
          libraries: [Host.library(name: ["app"], primitives: [{"price", 1, fn [x] -> x end}])]
        )

      assert [d] = check("(import (app))\n(price)", environment)
      assert d.message == "arity mismatch in `price`: expected 1, got 0"
      assert summary([d]) == [{:error, :arity, {"t.scm", 2, 1}}]
    end

    test "the location has no file without :file" do
      assert [%Diagnostic{location: %Location{file: nil, line: 1, column: 1}}] =
               Schooner.check("(car)", env())
    end

    test "diagnostics are ordered by location" do
      assert summary(check("(car)\n(import)\n(cdr)")) |> Enum.map(&elem(&1, 2)) == [
               {"t.scm", 1, 1},
               {"t.scm", 2, 2},
               {"t.scm", 3, 1}
             ]
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, fn -> Schooner.check("1", env(), debug: true) end
    end
  end

  describe "no false positives" do
    test "forward references between top-level definitions" do
      assert check("(define (even? n) (if (= n 0) #t (odd? (- n 1))))
                    (define (odd? n) (if (= n 0) #f (even? (- n 1))))") == []
    end

    test "names bound by define-record-type" do
      assert check("""
             (define-record-type point (make-point x y) point? (x point-x) (y point-y))
             (define (norm p) (+ (point-x p) (point-y p)))
             (if (point? (make-point 1 2)) (norm (make-point 1 2)))
             (define (local) (define-record-type cell (make-cell v) cell? (v cell-v)) (cell-v (make-cell 1)))
             """) == []
    end

    test "names bound by define-values" do
      assert check("""
             (define-values (q r) (floor/ 7 2))
             (define-values (first . rest) (values 1 2 3))
             (define (f) (define-values (a b) (values 1 2)) (+ a b q r first))
             """) == []
    end

    test "internal defines" do
      assert check("(define (f x) (define y (* x 2)) (define (g) (+ y 1)) (g))") == []
    end

    test "named let and do" do
      assert check("""
             (let loop ((i 0) (acc '())) (if (< i 3) (loop (+ i 1) (cons i acc)) acc))
             (do ((i 0 (+ i 1)) (acc '() (cons i acc))) ((= i 3) acc))
             """) == []
    end

    test "case-lambda" do
      environment = Environment.new(pre_imports: [["scheme", "base"], ["scheme", "case-lambda"]])

      assert check(
               "(define area (case-lambda ((r) (* r r)) ((w h) (* w h)))) (area 1) (area 1 2)",
               environment
             ) == []
    end

    test "guard and parameterize" do
      assert check("""
             (guard (e ((symbol? e) e) ((string? e) => string-length) (else 'other)) (raise 'x))
             (define p (make-parameter 1))
             (parameterize ((p 2)) (p))
             """) == []
    end

    test "hygienically marked names that fall back to their base name" do
      assert check("""
             (define-syntax my-or
               (syntax-rules () ((_ a b) (let ((t a)) (if t t b)))))
             (define t 5)
             (my-or #f t)
             (define-syntax twice (syntax-rules () ((_ e) (list e e))))
             (twice (car '(1)))
             """) == []
    end

    test "a lexical binding shadows a primitive's arity" do
      assert check("(let ((car (lambda (a b c) a))) (car 1 2 3))") == []
    end

    test "a top-level definition over an import leaves the arity unknown" do
      # The import's `car` runs before the script's replaces it.
      source = "(car '(1)) (define (car a b c) a) (car 1 2 3)"
      assert {:ok, 1} = Schooner.eval(source, env())
      assert check(source) == []
      assert check("(if #f (define (car a b c) a)) (car '(1))") == []
    end

    test "names a malformed top-level form would define" do
      assert [%Diagnostic{code: :syntax_error}] = check("(define (f) (if))\n(f)")

      assert [%Diagnostic{code: :syntax_error}] =
               check("(define-syntax m (syntax-rules))\n(m 1)")

      assert [%Diagnostic{code: :syntax_error}] = check("(define (f) 1 (define y 2) y)\n(f)")
    end

    test "a macro's definition over a bound name leaves the arity unknown" do
      source = """
      (define-syntax redefine-car
        (syntax-rules () ((_) (begin (car '(1)) (define (car a b c) a) (car 1 2 3)))))
      (redefine-car)
      """

      assert {:ok, 1} = Schooner.eval(source, env())
      assert check(source) == []
    end

    test "a macro's definition over a local procedure leaves the arity unknown" do
      source = """
      (define-syntax m (syntax-rules () ((_) (if #f (define (f a) a) (f 1 2)))))
      (let ((f (lambda (a b) a))) (m))
      """

      assert {:ok, 1} = Schooner.eval(source, env())
      assert check(source) == []
    end

    test "a name defined more than once has no known arity" do
      assert check("(define (f a) a) (define (f a b) a) (f 1 2)") == []
    end

    test "the conformance scripts, with the harness prepended" do
      dir = "test/conformance/scheme"
      harness = File.read!(Path.join(dir, "_harness.scm"))

      for path <- Path.wildcard(Path.join(dir, "[0-9]*.scm")) do
        source = harness <> "\n" <> File.read!(path)
        assert {path, Schooner.check(source, Environment.new())} == {path, []}
      end
    end

    test "the standard library sources" do
      for path <- Path.wildcard("priv/scheme/*.scm") do
        assert {path, Schooner.check(File.read!(path), Environment.new())} == {path, []}
      end
    end
  end
end

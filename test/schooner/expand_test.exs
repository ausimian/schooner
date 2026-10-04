defmodule Schooner.ExpandTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Expander
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Host
  alias Schooner.Location
  alias Schooner.Pretty
  alias Schooner.Reader

  defp env, do: Environment.new(pre_imports: [["scheme", "base"]])

  # The expansion of `source`, one line per top-level form.
  defp expand(source, opts \\ []) do
    assert {:ok, forms} = Schooner.expand(source, env(), opts)
    Enum.map(forms, &Pretty.format(&1, width: 1000))
  end

  defp trace(source, opts \\ []) do
    assert {:ok, _forms, steps} = Schooner.expand(source, env(), [trace: true] ++ opts)

    Enum.map(steps, fn step ->
      {step.macro, step.location && {step.location.line, step.location.column},
       Pretty.format(step.before, width: 1000), Pretty.format(step.after, width: 1000)}
    end)
  end

  describe "the derived forms of (scheme base)" do
    # Every rule of every macro in priv/scheme/base.scm, expanded to
    # core forms.
    @expansions [
      {"(when a b c)", "(if a (begin b c))"},
      {"(unless a b c)", "(if a (begin) (begin b c))"},
      {"(and)", "#t"},
      {"(and a)", "a"},
      {"(and a b c)", "(if a (if b c #f) #f)"},
      {"(or)", "#f"},
      {"(or a)", "a"},
      {"(or a b c)", "((lambda (t·1) (if t·1 t·1 ((lambda (t·2) (if t·2 t·2 c)) b))) a)"},
      {"(let () a b)", "((lambda () a b))"},
      {"(let ((x 1) (y 2)) (+ x y))", "((lambda (x y) (+ x y)) 1 2)"},
      {"(let loop ((i 0)) (loop i))", "(letrec* ((loop (lambda (i) (loop i)))) (loop 0))"},
      {"(let* () a)", "((lambda () a))"},
      {"(let* ((x 1) (y x)) y)", "((lambda (x) ((lambda (y) ((lambda () y))) x)) 1)"},
      {"(letrec ((f (lambda () (g))) (g (lambda () (f)))) (f))",
       "(letrec* ((f (lambda () (g))) (g (lambda () (f)))) (f))"},
      {"(cond)", "(begin)"},
      {"(cond (else a b))", "(begin a b)"},
      {"(cond (a => f))", "((lambda (tmp·1) (if tmp·1 (f tmp·1))) a)"},
      {"(cond (a => f) (else b))", "((lambda (tmp·1) (if tmp·1 (f tmp·1) (begin b))) a)"},
      {"(cond (a))", "a"},
      {"(cond (a) (else b))", "((lambda (tmp·1) (if tmp·1 tmp·1 (begin b))) a)"},
      {"(cond (a b))", "(if a (begin b))"},
      {"(cond (a b) (else c))", "(if a (begin b) (begin c))"},
      {"(case k)", "(begin)"},
      {"(case k (else => f))", "((lambda (k·1) (f k·1)) k)"},
      {"(case k (else a))", "(begin a)"},
      {"(case k ((1 2) => f))", "((lambda (k·1) (if (memv·1 k·1 '(1 2)) (f k·1))) k)"},
      {"(case k ((1) => f) (else a))",
       "((lambda (k·1) (if (memv·1 k·1 '(1)) (f k·1) (begin a))) k)"},
      {"(case k ((1 2) a))", "((lambda (k·1) (if (memv·1 k·1 '(1 2)) (begin a))) k)"},
      {"(case k ((1) a) (else b))",
       "((lambda (k·1) (if (memv·1 k·1 '(1)) (begin a) (begin b))) k)"},
      {"(do ((i 0 (+ i 1)) (acc '())) ((= i 3) acc) (f i))",
       "(letrec* ((loop·1 (lambda (i acc) (if (= i 3) (begin (begin) acc) " <>
         "(begin (f i) (loop·1 (+ i 1) acc)))))) (loop·1 0 '()))"},
      {"(let-values (((a b) (values 1 2)) (c (values 3))) (list a b c))",
       "(call-with-values·1 (lambda () (values 1 2)) (lambda (x·2 x·3) " <>
         "(call-with-values·4 (lambda () (values 3)) " <>
         "(lambda c ((lambda (a b) (begin (list a b c))) x·2 x·3)))))"},
      {"(let*-values () a)", "((lambda () a))"},
      {"(let*-values (((a) (values 1)) ((b) (values a))) b)",
       "(call-with-values·1 (lambda () (values 1)) (lambda (x·2) ((lambda (a) " <>
         "(begin (call-with-values·3 (lambda () (values a)) " <>
         "(lambda (x·4) ((lambda (b) (begin ((lambda () b)))) x·4))))) x·2)))"},
      {"(parameterize ((p 1) (q 2)) (p))",
       "(%parameterize-apply·1 (list·1 (cons·1 p 1) (cons·1 q 2)) (lambda () (p)))"}
    ]

    for {source, expansion} <- @expansions do
      test source do
        assert expand(unquote(source)) == [unquote(expansion)]
      end
    end

    test "cover every macro in priv/scheme/base.scm" do
      defined =
        ~r/\(define-syntax ([^\s]+)/
        |> Regex.scan(File.read!("priv/scheme/base.scm"), capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      expanded =
        for {source, _} <- @expansions, step <- trace(source), into: MapSet.new() do
          elem(step, 0)
        end

      assert MapSet.subset?(defined, expanded), inspect(MapSet.difference(defined, expanded))
    end
  end

  describe "step: :once" do
    test "leaves the macro uses in a cond's expansion unexpanded" do
      assert expand("(cond ((> x 0) (when y 1)) (else (or a b)))", step: :once) ==
               ["(if (> x 0) (begin (when y 1)) (cond·1 (else (or a b))))"]
    end

    test "expands every macro use that is not inside another, inside core forms" do
      assert expand("(define (f x) (if (and x y) (unless x 1) 2))", step: :once) ==
               ["(define (f x) (if (if x (and·1 y) #f) (if x (begin) (begin 1)) 2))"]
    end

    test "leaves core forms as they are" do
      assert expand("(define x (lambda (y) (if y 'a \"b\")))", step: :once) ==
               ["(define x (lambda (y) (if y 'a \"b\")))"]
    end

    test "is the first step of the full expansion" do
      [{_, _, _, first}] = trace("(let loop ((i 0)) (loop (+ i 1)))", step: :once)
      assert expand("(let loop ((i 0)) (loop (+ i 1)))", step: :once) == [first]
    end
  end

  describe "trace: true" do
    test "lists a user macro and the user macro it expands into, in order, at the use sites" do
      source = """
      (define-syntax my-unless
        (syntax-rules () ((_ c e) (my-if c #f e))))
      (define-syntax my-if
        (syntax-rules () ((_ c a b) (if c a b))))
      (define (f x)
        (my-unless (> x 0) 'negative))
      """

      assert trace(source) == [
               {"my-unless", {6, 3}, "(my-unless (> x 0) 'negative)",
                "(my-if·1 (> x 0) #f 'negative)"},
               {"my-if", {6, 3}, "(my-if·1 (> x 0) #f 'negative)", "(if (> x 0) #f 'negative)"}
             ]
    end

    test "places a macro use the script wrote at that use" do
      assert [{"let", {1, 1}, _, _}, {"when", {1, 19}, _, _}] =
               trace("(let loop ((i 0)) (when (< i 3) (loop (+ i 1))))")
    end

    test "names the file in each location" do
      assert {:ok, _, [%{location: %Location{file: "t.scm", line: 2, column: 1}}]} =
               Schooner.expand("(define x 1)\n(when x 2)", env(), trace: true, file: "t.scm")
    end

    test "lists only the expanded steps with step: :once" do
      assert [{"cond", {1, 1}, _, _}] = trace("(cond (a 1) (b 2))", step: :once)
    end

    test "is empty when there are no macro uses" do
      assert trace("(define x 1)") == []
    end

    test "an expansion started during another leaves the outer one's trace intact" do
      outer = :erlang.unique_integer([:positive])
      # A transformer that runs a whole expand/3 of its own, as a macro
      # implemented in Elixir could.
      nested = fn _form, tree ->
        {:ok, _, [_]} = Schooner.expand("(when a b)", env(), trace: true)
        {outer, tree}
      end

      syntax_env = SyntaxEnv.define_macro(env().syntax_env, "nested", nested)
      forms = Reader.read_string_positioned("(unless (nested) c)")

      assert {[{form, _}], steps} =
               Expander.inspect_positioned(forms, syntax_env, :full, true)

      assert Pretty.format(form) == "(if #{outer} (begin) (begin c))"
      assert Enum.map(steps, &elem(&1, 0)) == ["unless", "nested"]
    end

    test "returns the same forms as without a trace" do
      source = "(case (f) ((1) (or a b)) (else (let* ((x 1)) x)))"
      assert {:ok, forms} = Schooner.expand(source, env())
      assert {:ok, ^forms, [_ | _]} = Schooner.expand(source, env(), trace: true)
    end
  end

  describe "hygiene" do
    @swap """
    (define-syntax swap
      (syntax-rules () ((_ a b) (let ((tmp a)) (list b tmp)))))
    (let ((tmp 1) (other 2))
      (swap tmp other))
    """

    test "an identifier a macro introduces is printed apart from the script's own" do
      assert expand(@swap) == [
               "((lambda (tmp other) ((lambda (tmp·1) (list·1 other tmp·1)) tmp)) 1 2)"
             ]
    end

    test "with plain names, it is printed as written" do
      assert {:ok, [form]} = Schooner.expand(@swap, env())

      assert Pretty.format(form, names: :plain) ==
               "((lambda (tmp other) ((lambda (tmp) (list other tmp)) tmp)) 1 2)"
    end

    test "numbers are assigned in order of appearance and are the same on every run" do
      assert expand("(or a b c)") == expand("(or a b c)")

      assert expand("(list (or a b) (or c d))") == [
               "(list ((lambda (t·1) (if t·1 t·1 b)) a) ((lambda (t·2) (if t·2 t·2 d)) c))"
             ]
    end
  end

  describe "the program" do
    test "imports are resolved, and neither they nor define-syntax forms are returned" do
      source = """
      (import (scheme base) (scheme case-lambda))
      (define-syntax m (syntax-rules () ((_) 1)))
      (define f (case-lambda ((x) (m))))
      """

      assert {:ok, [form]} = Schooner.expand(source, Environment.new())
      assert Pretty.format(form, width: 1000) =~ ~r/^\(define f \(lambda args·1 \(if .* 1\)/
    end

    test "without the import, a library's macro is left as an application" do
      assert {:ok, [form]} = Schooner.expand("(case-lambda ((x) x))", Environment.new())
      assert Pretty.format(form) == "(case-lambda ((x) x))"
    end

    test "macros defined in a top-level begin are used by later forms" do
      assert expand("(begin (define-syntax one (syntax-rules () ((_) 1))) (define x 0))\n(one)") ==
               ["(begin (define x 0))", "1"]
    end

    test "a local binding shadows a macro" do
      assert expand("(lambda (when) (when 1 2))") == ["(lambda (when) (when 1 2))"]
    end
  end

  describe "errors" do
    test "a read error, located" do
      assert {:error, %Schooner.Reader.Error{location: %Location{file: "t.scm", line: 1}}} =
               Schooner.expand("(when", env(), file: "t.scm")
    end

    test "an unknown library, at the import spec" do
      assert {:error, %Schooner.Library.NotFoundError{location: location}} =
               Schooner.expand("(import (no such))", env(), file: "t.scm")

      assert location == %Location{file: "t.scm", line: 1, column: 9}
    end

    test "a malformed macro use, at the use" do
      assert {:error, %Schooner.Eval.Error{location: location} = e} =
               Schooner.expand("(define x 1)\n(when)", env(), file: "t.scm")

      assert location == %Location{file: "t.scm", line: 2, column: 1}
      assert Exception.message(e) =~ "t.scm:2:1: "
    end

    test "invalid options raise" do
      assert_raise ArgumentError, ~r/:step/, fn -> Schooner.expand("1", env(), step: :twice) end
      assert_raise ArgumentError, ~r/:trace/, fn -> Schooner.expand("1", env(), trace: 1) end
      assert_raise ArgumentError, ~r/unknown keys/, fn -> Schooner.expand("1", env(), x: 1) end
    end
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

    test "a script that would raise, loop forever or call a host primitive",
         %{environment: environment} do
      source = """
      (notify 1)
      (define x (notify 2))
      (define (spin n) (spin (+ n 1)))
      (when (notify x) (spin 0))
      (raise 'boom)
      """

      assert {:ok, [_, _, _, _, _]} = Schooner.expand(source, environment)
      assert {:ok, _, _} = Schooner.expand(source, environment, trace: true, step: :once)
      refute_received {:notified, _}
    end

    test "leaves the environment unchanged", %{environment: environment} do
      assert {:ok, _} = Schooner.expand("(import (scheme char))\n(define y 1)", environment)

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "y"}}} =
               Schooner.eval("y", environment)

      assert {:error, %Schooner.Eval.Error{reason: {:unbound, "char-upcase"}}} =
               Schooner.eval("char-upcase", environment)
    end
  end

  describe "guides/tooling.md" do
    @guide File.read!("guides/tooling.md")

    defp section, do: hd(Regex.run(~r/## Inspecting macro expansion\n.*?(?=\n## )/s, @guide))

    test "marks the section available" do
      assert section() =~ "**Status: Available** ([#140]"

      assert @guide =~
               "| 6 | [Inspecting macro expansion](#inspecting-macro-expansion) | Available |"
    end

    test "the expand/3 example" do
      [_, call, expected] =
        Regex.run(
          ~r/```elixir\n(\{:ok, \[form\]\} = Schooner\.expand.*?)\n# (.*?)\n```/s,
          section()
        )

      call =
        call
        |> String.replace(
          "MyApp.Scripts.environment()",
          "Schooner.Environment.new(pre_imports: [[\"scheme\", \"base\"]])"
        )
        |> String.replace("IO.puts(", "(")

      {printed, _} = Code.eval_string(call)
      assert printed == expected
    end
  end
end

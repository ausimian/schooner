defmodule Schooner.Expander.SyntaxRulesTest do
  # Phase 9 — pattern matcher and template instantiator tests in
  # isolation. The full transformer is exercised via `compile/1`
  # against synthetic forms; we never go through the runtime so
  # failures here pin behaviour at the macro layer regardless of
  # what the rest of the pipeline does.
  #
  # Free identifiers in templates pick up a per-expansion hygiene
  # mark, so structural comparisons strip those marks via `unmark/1`
  # before equality. The mark itself is what `strip_mark/1` does at
  # the evaluator's fallback lookup; here we just want to assert the
  # template's *shape* matches the spec.
  use ExUnit.Case, async: true

  alias Schooner.Expander.SyntaxRules
  alias Schooner.Reader

  defp transformer(source) do
    [spec] = Reader.read_string(source)
    SyntaxRules.compile(spec)
  end

  defp form(source) do
    [datum] = Reader.read_string(source)
    datum
  end

  defp expand(transformer, source), do: transformer.(form(source))

  defp unmark({:sym, name}) do
    case SyntaxRules.strip_mark(name) do
      {:ok, base} -> {:sym, base}
      :error -> {:sym, name}
    end
  end

  defp unmark([h | t]), do: [unmark(h) | unmark(t)]

  defp unmark({:vector, t}),
    do: {:vector, t |> Tuple.to_list() |> Enum.map(&unmark/1) |> List.to_tuple()}

  defp unmark(other), do: other

  defp assert_form_equal(result, expected_source) do
    assert unmark(result) == form(expected_source)
  end

  describe "patterns: literals, wildcards, identifiers" do
    test "wildcard matches anything" do
      t = transformer("(syntax-rules () ((_ _) 'matched))")
      assert_form_equal(expand(t, "(use 1)"), "'matched")
      assert_form_equal(expand(t, "(use foo)"), "'matched")
      assert_form_equal(expand(t, "(use (a b c))"), "'matched")
    end

    test "literal identifier in pattern matches by name only" do
      t = transformer("(syntax-rules (=>) ((_ a => b) (list a b)))")
      assert_form_equal(expand(t, "(use 1 => 2)"), "(list 1 2)")

      assert_raise Schooner.Eval.Error, fn -> expand(t, "(use 1 -> 2)") end
    end

    test "constant pattern matches by eqv?" do
      t =
        transformer("""
        (syntax-rules ()
          ((_ 0) 'zero)
          ((_ x) (cons 'other x)))
        """)

      assert_form_equal(expand(t, "(n 0)"), "'zero")
      assert_form_equal(expand(t, "(n 1)"), "(cons 'other 1)")
      # Floats and integers are not eqv? in Schooner — a different
      # exactness must therefore fall through to the next rule.
      assert_form_equal(expand(t, "(n 0.0)"), "(cons 'other 0.0)")
    end
  end

  describe "patterns: lists" do
    test "fixed-length list pattern" do
      t = transformer("(syntax-rules () ((_ a b c) (list c b a)))")
      assert_form_equal(expand(t, "(use 1 2 3)"), "(list 3 2 1)")
      assert_raise Schooner.Eval.Error, fn -> expand(t, "(use 1 2)") end
      assert_raise Schooner.Eval.Error, fn -> expand(t, "(use 1 2 3 4)") end
    end

    test "dotted (improper) pattern binds the cdr" do
      t = transformer("(syntax-rules () ((_ a . rest) (list a rest)))")
      assert_form_equal(expand(t, "(use 1 2 3)"), "(list 1 (2 3))")
      assert_form_equal(expand(t, "(use 1)"), "(list 1 ())")
    end

    test "empty-list literal in pattern" do
      t =
        transformer("""
        (syntax-rules ()
          ((_ ()) 'empty)
          ((_ xs) (cons 'non-empty xs)))
        """)

      assert_form_equal(expand(t, "(use ())"), "'empty")
      assert_form_equal(expand(t, "(use (1 2))"), "(cons 'non-empty (1 2))")
    end
  end

  describe "patterns: ellipsis" do
    test "trailing ellipsis collects every remaining arg" do
      t = transformer("(syntax-rules () ((_ x ...) (list x ...)))")
      assert_form_equal(expand(t, "(u)"), "(list)")
      assert_form_equal(expand(t, "(u 1)"), "(list 1)")
      assert_form_equal(expand(t, "(u 1 2 3)"), "(list 1 2 3)")
    end

    test "ellipsis with surrounding fixed elements" do
      t = transformer("(syntax-rules () ((_ a b ... z) (list a (list b ...) z)))")
      assert_form_equal(expand(t, "(u 1 2)"), "(list 1 (list) 2)")
      assert_form_equal(expand(t, "(u 1 2 3 4 5)"), "(list 1 (list 2 3 4) 5)")
    end

    test "nested ellipsis preserves the outer/inner structure" do
      t =
        transformer("""
        (syntax-rules ()
          ((_ (a ...) ...) (list (list a ...) ...)))
        """)

      assert_form_equal(
        expand(t, "(u (1 2) (3 4 5) ())"),
        "(list (list 1 2) (list 3 4 5) (list))"
      )
    end

    test "two pattern variables under one ellipsis stay paired" do
      t = transformer("(syntax-rules () ((_ (a b) ...) (list (cons a b) ...)))")

      assert_form_equal(
        expand(t, "(u (1 2) (3 4))"),
        "(list (cons 1 2) (cons 3 4))"
      )
    end
  end

  describe "patterns: vectors" do
    test "fixed vector pattern matches by length" do
      t = transformer("(syntax-rules () ((_ #(a b)) (cons a b)))")
      assert_form_equal(expand(t, "(u #(1 2))"), "(cons 1 2)")
      assert_raise Schooner.Eval.Error, fn -> expand(t, "(u #(1 2 3))") end
    end

    test "vector pattern with ellipsis collects items" do
      t = transformer("(syntax-rules () ((_ #(x ...)) (list x ...)))")
      assert_form_equal(expand(t, "(u #(1 2 3))"), "(list 1 2 3)")
      assert_form_equal(expand(t, "(u #())"), "(list)")
    end
  end

  describe "templates: pattern variables" do
    test "pvar is replaced by its bound subform verbatim" do
      t = transformer("(syntax-rules () ((_ x) (list x x x)))")
      assert_form_equal(expand(t, "(u (a b))"), "(list (a b) (a b) (a b))")
    end

    test "pvar used outside ellipsis when it was bound under ellipsis raises" do
      t = transformer("(syntax-rules () ((_ x ...) (list x)))")
      assert_raise Schooner.Expander.Error, fn -> expand(t, "(u 1 2 3)") end
    end
  end

  describe "templates: hygiene marking" do
    test "free identifier in template carries a per-expansion mark" do
      t = transformer("(syntax-rules () ((_ x) (foo x)))")
      result = expand(t, "(u 7)")
      assert [{:sym, marked} | [7 | []]] = result
      assert {:ok, "foo"} = SyntaxRules.strip_mark(marked)
    end

    test "core keywords in template are emitted unmarked" do
      t = transformer("(syntax-rules () ((_ x) (lambda (x) x)))")
      result = expand(t, "(u y)")
      assert [{:sym, "lambda"} | _] = result
    end

    test "two expansions of the same template get distinct marks" do
      t = transformer("(syntax-rules () ((_) foo))")
      {:sym, name1} = expand(t, "(u)")
      {:sym, name2} = expand(t, "(u)")
      assert name1 != name2
      assert SyntaxRules.strip_mark(name1) == {:ok, "foo"}
      assert SyntaxRules.strip_mark(name2) == {:ok, "foo"}
    end
  end

  describe "templates: quote" do
    test "non-pattern-variable identifier inside quote emits a literal symbol" do
      t = transformer("(syntax-rules () ((_) 'literal-name))")
      assert_form_equal(expand(t, "(u)"), "'literal-name")
    end

    test "pattern variable inside quote substitutes the bound subform" do
      t = transformer("(syntax-rules () ((_ x) '(wrapping x)))")
      assert_form_equal(expand(t, "(u 99)"), "'(wrapping 99)")
    end

    test "ellipsis inside quote produces a quoted spread" do
      t = transformer("(syntax-rules () ((_ x ...) '(items x ...)))")
      assert_form_equal(expand(t, "(u a b c)"), "'(items a b c)")
    end
  end

  describe "compile errors" do
    test "duplicate pattern variable raises" do
      assert_raise Schooner.Expander.Error, fn ->
        transformer("(syntax-rules () ((_ x x) x))")
      end
    end

    test "two ellipses in one list raise" do
      assert_raise Schooner.Expander.Error, fn ->
        transformer("(syntax-rules () ((_ a ... b ...) (list a b)))")
      end
    end

    test "stray ellipsis in template is rejected at compile time" do
      assert_raise Schooner.Expander.Error, fn ->
        transformer("(syntax-rules () ((_ x) ...))")
      end
    end

    test "syntax-rules with a non-list literals form is rejected" do
      assert_raise Schooner.Expander.Error, fn -> transformer("(syntax-rules 1 ((_) 'x))") end
    end

    test "syntax-rules with non-symbol literal entries is rejected" do
      assert_raise Schooner.Expander.Error, fn -> transformer("(syntax-rules (1) ((_) 'x))") end
    end

    test "syntax-rules with a malformed rule shape is rejected" do
      assert_raise Schooner.Expander.Error, fn -> transformer("(syntax-rules () (foo))") end
    end

    test "syntax-rules called on a non-pair spec is rejected" do
      assert_raise Schooner.Expander.Error, fn -> SyntaxRules.compile([]) end
    end

    test "no matching rule reports the form's keyword" do
      t = transformer("(syntax-rules () ((_ x y) (list x y)))")
      e = assert_raise Schooner.Eval.Error, fn -> expand(t, "(use 1)") end
      assert e.reason == {:bad_special_form, "use"}
    end
  end

  describe "strip_mark/1" do
    test "round-trips a marked name back to its base" do
      # The mark separator is a NUL byte: invalid in r7rs identifiers
      # so it can never collide with a user-written name. The exact
      # encoding is internal to SyntaxRules; we synthesise one here
      # purely to confirm strip_mark is the inverse of marking.
      marked = "foo" <> <<0>> <> "42"
      assert SyntaxRules.strip_mark(marked) == {:ok, "foo"}
    end

    test "returns :error on a name without a mark" do
      assert SyntaxRules.strip_mark("foo") == :error
    end
  end
end

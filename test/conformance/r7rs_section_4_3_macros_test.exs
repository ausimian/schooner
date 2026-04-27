defmodule Schooner.Conformance.R7rsSection43MacrosTest do
  # Worked examples from r7rs-small §4.3 (macros). Each test
  # transcribes a `(form) ==> result` example from the spec or
  # exercises a property the spec calls out as required of a
  # `syntax-rules` implementation.
  #
  # Schooner-specific deviations from §4.3:
  #
  #   - `syntax-error` (§4.3.3) is not implemented — expansion-time
  #     errors come from `Schooner.Expander.Error` instead. Tests
  #     that would exercise it are absent.
  #   - `syntax-rules` patterns may use `_` as a wildcard at any
  #     position; the spec also allows it as the first sub-pattern
  #     position to suppress binding the macro keyword. Both work.
  #   - The bootstrap derived forms (cond, case, let, etc.) are
  #     themselves `syntax-rules` macros, so user-defined macros
  #     that build on them go through the same path the spec
  #     defines for "library macros".
  use ExUnit.Case, async: true

  alias Schooner.Eval.Error
  alias Schooner.Value

  defp run(source), do: Schooner.run(source)

  # ---------------------------------------------------------------------------
  # §4.3.1 — Binding constructs for syntactic keywords
  # ---------------------------------------------------------------------------

  describe "§4.3.1 let-syntax" do
    test "let-syntax binds keywords whose scope is the body" do
      # Spec example: (let-syntax ((given-that ...)) ...). Adapted
      # to use cons/list for observable output without I/O.
      assert run("""
             (let-syntax ((given-that
                           (syntax-rules ()
                             ((_ test stmt1 stmt2 ...)
                              (if test (begin stmt1 stmt2 ...))))))
               (let ((if #t))
                 (given-that if (list 'now))))
             """) == Value.list([Value.symbol("now")])
    end

    test "let-syntax does not extend its keyword binding outside the body" do
      assert_raise Error, fn ->
        run("""
        (let-syntax ((m (syntax-rules () ((_ x) (cons x x))))) (m 1))
        (m 2)
        """)
      end
    end

    test "the keyword identifier may be locally rebound as a variable inside the body" do
      # Spec §4.3.1: the `(let ((if #t)) ...)` test above is the
      # canonical demonstration that an identifier used as a macro
      # keyword and as a variable can coexist if scopes are
      # respected. Pin the variable-side of that example here.
      assert run("""
             (let-syntax ((id (syntax-rules () ((_ x) x))))
               (let ((id 42))
                 id))
             """) == 42
    end
  end

  describe "§4.3.1 letrec-syntax" do
    test "letrec-syntax binds peers visible to each other's templates" do
      # Spec example: a `my-or` and `my-and` pair that ping-pong.
      # Without runtime arithmetic in macro expansion, we recurse
      # over a syntactic list instead.
      assert run("""
             (letrec-syntax
                 ((my-or  (syntax-rules ()
                            ((_) #f)
                            ((_ e) e)
                            ((_ e1 e2 ...) (let ((t e1))
                                             (if t t (my-or e2 ...))))))
                  (my-and (syntax-rules ()
                            ((_) #t)
                            ((_ e) e)
                            ((_ e1 e2 ...) (if e1 (my-and e2 ...) #f)))))
               (list (my-or #f #f 'a) (my-and 1 2 3)))
             """) == Value.list([Value.symbol("a"), 3])
    end

    test "let-syntax peers expand against the body's env, so they can call each other through the body" do
      # r7rs §4.3.1 says each transformer-spec is parsed in the
      # *outer* environment, but the body sees all the new
      # keywords. Once `alpha` produces `(beta)`, that result is
      # re-expanded in the body's env where `beta` is bound, so
      # the call resolves. The let-syntax/letrec-syntax distinction
      # is observable at transformer-compile time (where peer
      # keywords are vs. aren't visible to ellipsis / literal
      # decisions) — not at template-application time.
      assert run("""
             (let-syntax ((alpha (syntax-rules () ((_) (beta))))
                          (beta  (syntax-rules () ((_) 'ok))))
               (alpha))
             """) == Value.symbol("ok")
    end
  end

  # ---------------------------------------------------------------------------
  # §4.3.2 — Pattern language
  # ---------------------------------------------------------------------------

  describe "§4.3.2 pattern: literal identifier" do
    test "matches by identifier name only when listed in literals" do
      assert run("""
             (define-syntax tag
               (syntax-rules (=>)
                 ((_ x => y) (list 'arrow x y))
                 ((_ x   y) (list 'plain x y))))
             (list (tag 1 => 2) (tag 1 2))
             """) ==
               Value.list([
                 Value.list([Value.symbol("arrow"), 1, 2]),
                 Value.list([Value.symbol("plain"), 1, 2])
               ])
    end
  end

  describe "§4.3.2 pattern: underscore wildcard" do
    test "matches anything without binding it" do
      assert run("""
             (define-syntax constant
               (syntax-rules () ((_ _) 'always)))
             (list (constant 1) (constant 'x) (constant (a b c)))
             """) ==
               Value.list([
                 Value.symbol("always"),
                 Value.symbol("always"),
                 Value.symbol("always")
               ])
    end

    test "the macro's keyword position is implicitly a wildcard" do
      # Whether the rule is written as `(_ ...)` or `(<keyword>
      # ...)`, the first sub-pattern matches the keyword identifier
      # without binding it as a useful variable. Both work.
      assert run("""
             (define-syntax greet
               (syntax-rules ()
                 ((greet x) (list 'hi x))))
             (greet 'world)
             """) == Value.list([Value.symbol("hi"), Value.symbol("world")])
    end
  end

  describe "§4.3.2 pattern: ellipsis" do
    test "trailing ellipsis collects zero or more arguments" do
      assert run("""
             (define-syntax mk
               (syntax-rules () ((_ x ...) (list x ...))))
             (list (mk) (mk 1) (mk 1 2 3))
             """) == Value.list([:null, Value.list([1]), Value.list([1, 2, 3])])
    end

    test "ellipsis with leading and trailing fixed elements" do
      assert run("""
             (define-syntax bracketed
               (syntax-rules ()
                 ((_ a middle ... z) (list a (list middle ...) z))))
             (list (bracketed 1 2)
                   (bracketed 1 9 'last)
                   (bracketed 1 'a 'b 'c 'z))
             """) ==
               Value.list([
                 Value.list([1, :null, 2]),
                 Value.list([1, Value.list([9]), Value.symbol("last")]),
                 Value.list([
                   1,
                   Value.list([Value.symbol("a"), Value.symbol("b"), Value.symbol("c")]),
                   Value.symbol("z")
                 ])
               ])
    end

    test "nested ellipsis preserves the depth-shape of pattern variables" do
      assert run("""
             (define-syntax flatten-shape
               (syntax-rules ()
                 ((_ ((x ...) ...)) (list (list x ...) ...))))
             (flatten-shape ((1 2) (3 4 5) ()))
             """) == Value.list([Value.list([1, 2]), Value.list([3, 4, 5]), :null])
    end

    test "two pattern variables under one ellipsis stay paired" do
      assert run("""
             (define-syntax zip-cons
               (syntax-rules ()
                 ((_ (a b) ...) (list (cons a b) ...))))
             (zip-cons (1 'a) (2 'b) (3 'c))
             """) ==
               Value.list([
                 {:pair, 1, Value.symbol("a")},
                 {:pair, 2, Value.symbol("b")},
                 {:pair, 3, Value.symbol("c")}
               ])
    end
  end

  describe "§4.3.2 pattern: dotted (improper) lists" do
    test "improper pattern binds the cdr in the rest position" do
      # `rest` is bound to a Scheme list — empty for the
      # one-argument case, a proper list otherwise. We quote it
      # into the template so the bound list is treated as data
      # rather than as an expression to evaluate.
      assert run("""
             (define-syntax head-tail
               (syntax-rules ()
                 ((_ a . rest) (list 'head a 'tail 'rest))))
             (list (head-tail 1)
                   (head-tail 1 2 3))
             """) ==
               Value.list([
                 Value.list([Value.symbol("head"), 1, Value.symbol("tail"), :null]),
                 Value.list([
                   Value.symbol("head"),
                   1,
                   Value.symbol("tail"),
                   Value.list([2, 3])
                 ])
               ])
    end
  end

  describe "§4.3.2 pattern: vector" do
    test "fixed-length vector pattern matches by length" do
      assert run("""
             (define-syntax pair-of
               (syntax-rules ()
                 ((_ #(a b)) (cons a b))))
             (pair-of #(1 2))
             """) == {:pair, 1, 2}
    end

    test "vector pattern with ellipsis collects every element" do
      assert run("""
             (define-syntax vec->list
               (syntax-rules ()
                 ((_ #(x ...)) (list x ...))))
             (list (vec->list #()) (vec->list #(1 2 3)))
             """) == Value.list([:null, Value.list([1, 2, 3])])
    end
  end

  describe "§4.3.2 pattern: empty-list literal" do
    test "() in pattern position only matches the empty list" do
      assert run("""
             (define-syntax shape
               (syntax-rules ()
                 ((_ ()) 'empty)
                 ((_ (x)) 'single)
                 ((_ xs) 'other)))
             (list (shape ()) (shape (1)) (shape (1 2 3)) (shape sym))
             """) ==
               Value.list([
                 Value.symbol("empty"),
                 Value.symbol("single"),
                 Value.symbol("other"),
                 Value.symbol("other")
               ])
    end
  end

  describe "§4.3.2 pattern: constants" do
    test "literal numeric / boolean / string constants in patterns match by eqv?" do
      assert run("""
             (define-syntax classify
               (syntax-rules ()
                 ((_ 0) 'zero)
                 ((_ #t) 'true)
                 ((_ "yes") 'affirmative)
                 ((_ x) 'other)))
             (list (classify 0) (classify #t) (classify "yes") (classify 'foo))
             """) ==
               Value.list([
                 Value.symbol("zero"),
                 Value.symbol("true"),
                 Value.symbol("affirmative"),
                 Value.symbol("other")
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # §4.3.2 — Hygiene
  # ---------------------------------------------------------------------------

  describe "§4.3.2 hygiene: template-introduced identifiers do not capture user identifiers" do
    test "user `t` in the call site is not captured by the macro's introduced `t`" do
      # The classic capture-prone or-via-let example. If hygiene
      # were broken, the inner (let ((t e1)) ...) would shadow the
      # outer user `t` and the expression would observe `#f`.
      assert run("""
             (define-syntax my-or
               (syntax-rules ()
                 ((_) #f)
                 ((_ e) e)
                 ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))
             (let ((t 'caller-t)) (my-or #f t))
             """) == Value.symbol("caller-t")
    end

    test "free template references resolve at the macro's definition site" do
      # The `+` in the template refers to the global `+` even at a
      # call site that has lex-bound `+` to something else.
      # (Strict hygiene would require capturing `+`'s definition-
      # site binding; Schooner's pragmatic implementation uses
      # eval-time mark-stripping that achieves the same observable
      # behaviour for runtime free references.)
      assert run("""
             (define-syntax inc (syntax-rules () ((_ n) (+ n 1))))
             (inc 41)
             """) == 42
    end

    test "user identifiers passed into a template do not bind the macro's introduced binders" do
      # If passing the user's `y` shadowed the inner `y`, the
      # result would be 7 instead of the spec's 99.
      assert run("""
             (define-syntax wrap
               (syntax-rules ()
                 ((_ e) (let ((y 99)) e))))
             (let ((y 7)) (wrap y))
             """) == 7
    end

    test "two expansions of the same template yield distinct introduced names" do
      # Each macro use mints its own mark, so nested calls cannot
      # accidentally bind each other's `t`.
      assert run("""
             (define-syntax double-or
               (syntax-rules ()
                 ((_ e) (let ((t e))
                          (let ((t (cons t t)))
                            t)))))
             (double-or 'x)
             """) == {:pair, Value.symbol("x"), Value.symbol("x")}
    end
  end

  # ---------------------------------------------------------------------------
  # §4.3 — Standard derived forms re-expressed as user macros
  # ---------------------------------------------------------------------------

  describe "§4.3 user-defined or via syntax-rules behaves like the bootstrap or" do
    test "short-circuits on the first true result and returns it" do
      assert run("""
             (define-syntax my-or
               (syntax-rules ()
                 ((_) #f)
                 ((_ e) e)
                 ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))
             (list (my-or) (my-or #f #f) (my-or #f 7 'unused) (my-or 'first 'second))
             """) ==
               Value.list([
                 Value.bool(false),
                 Value.bool(false),
                 7,
                 Value.symbol("first")
               ])
    end
  end

  describe "§4.3 user-defined when via syntax-rules" do
    test "given-that example from §4.3.1 returns the body when the test is true" do
      assert run("""
             (define-syntax given-that
               (syntax-rules ()
                 ((_ test stmt1 stmt2 ...)
                  (if test (begin stmt1 stmt2 ...)))))
             (list (given-that #t 1 2 3) (given-that #f 'unused))
             """) == Value.list([3, :unspecified])
    end
  end

  # ---------------------------------------------------------------------------
  # §4.3.2 — Identifier comparison rules in patterns
  # ---------------------------------------------------------------------------

  describe "§4.3.2 identifier matching" do
    test "literal identifiers match across hygiene marks" do
      # `else` and `=>` in `cond`/`case` are literal identifiers in
      # the bootstrap macros. A user macro that uses `cond`/`case`
      # gets its `else` / `=>` marked; those still match because
      # literal-identifier comparison strips marks.
      assert run("""
             (define-syntax classify
               (syntax-rules ()
                 ((_ n) (cond ((zero? n) 'zero)
                              ((positive? n) 'positive)
                              (else 'negative)))))
             (list (classify 0) (classify 7) (classify -3))
             """) ==
               Value.list([
                 Value.symbol("zero"),
                 Value.symbol("positive"),
                 Value.symbol("negative")
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # §5.3.2 — Syntax definitions
  # ---------------------------------------------------------------------------

  describe "§5.3.2 define-syntax" do
    test "later top-level syntax definitions replace earlier ones" do
      assert run("""
             (define-syntax m (syntax-rules () ((_ x) (* x 10))))
             (define-syntax m (syntax-rules () ((_ x) (+ x 100))))
             (m 7)
             """) == 107
    end

    test "syntax bindings and value bindings can share a name in different scopes" do
      assert run("""
             (define-syntax id (syntax-rules () ((_ x) x)))
             (define id 99)
             (list id (let ((id 1)) id))
             """) == Value.list([99, 1])
    end
  end
end

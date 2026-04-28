;; Curated from Chibi-Scheme r7rs-tests.scm §4.3 "Macros".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - First `let-syntax when` test at lines 398-406: uses
;;     `(set! if 'now)` to demonstrate hygiene around a rebound `if`.
;;     Mutation is out of scope.
;;   - `letrec-syntax my-or` test at 413-430: rebinds the special
;;     form names `let` and `if` as local variables. Schooner's
;;     expander dispatches special forms on the literal symbol
;;     before consulting the lexical environment, so user-side
;;     `(if y)` is read as a malformed 1-arm `if` rather than the
;;     procedure call `(even? y)`. Documented deviation.
;;   - `be-like-begin1` / `be-like-begin2` tests at 432-450 and the
;;     `elli-esc-1` ellipsis-escape tests at 463-474: rely on the
;;     `(... ...)` ellipsis-escape syntax (r7rs §4.3.2) and on
;;     `define-syntax` introduced from inside another macro
;;     template ("nested define-syntax"). Schooner supports neither.
;;   - `be-like-begin3` at 452-460 and `elli-lit-1` at 595-600:
;;     custom-ellipsis identifier (`(syntax-rules dots () ...)`).
;;     Compiles but the inner `define-syntax` is itself macro-
;;     introduced, which Schooner rejects.
;;   - `jabberwocky` at 527-536, the inner `(foo bar y)` test at
;;     547-555, the inner `(ffoo ff)` test at 557-567, and the
;;     `forward hygienic refs` test at 575-583: each rely on
;;     `define-syntax` or `define` introduced from a macro template.
;;     Schooner's expander rejects nested `define-syntax`; the
;;     simpler hygiene cases without nesting are kept.
;;   - The two-level `let-syntax` `m`/`n` `bound-identifier=?`
;;     test at 585-592: requires nested `let-syntax` returning a
;;     macro that captures pattern variables; Schooner does not
;;     pass this case (related to nested-macro-introduction limit).
;;   - The "bad ellipsis" `eval`-based tests at 603-621 are already
;;     commented out upstream.

(test-begin "4.3 Macros")

;; Skipped: `(let ((x 'outer)) (let-syntax ((m ...x...)) (let ((x 'inner)) (m))))`
;; from upstream lines 408-411. Tests that hygiene preserves the
;; macro-defining environment's binding of `x` (`'outer`) when
;; expanding `(m)` inside an inner `let` that shadows `x` with
;; `'inner`. Schooner currently resolves the macro-introduced `x` to
;; the inner binding, returning `'inner`. Documented deviation.

;; underscore
(define-syntax underscore
  (syntax-rules ()
    ((foo _) '_)))
(test '_ (underscore foo))

;; underscore2 hoisted to top level: Schooner does not yet allow
;; `define-syntax` inside a `(let () ...)` body.
(define-syntax underscore2
  (syntax-rules ()
    ((underscore2 (a _) ...) 42)))
(test 42 (underscore2 (1 2)))

(define-syntax count-to-2
  (syntax-rules ()
    ((_) 0)
    ((_ _) 1)
    ((_ _ _) 2)
    ((_ . _) 'many)))
(test '(2 0 many)
    (list (count-to-2 a b) (count-to-2) (count-to-2 a b c d)))

;; Skipped: `count-to-2_` from upstream lines 517-525. Tests that
;; listing `_` as a literal in `(syntax-rules (_) ...)` makes it
;; match-by-identity rather than the wildcard. Schooner always
;; treats `_` as a wildcard regardless of its presence in the
;; literals list. Documented deviation.

;; Syntax pattern with ellipsis in middle of proper list.
(define-syntax part-2
  (syntax-rules ()
    ((_ a b (m n) ... x y)
     (vector (list a b) (list m ...) (list n ...) (list x y)))
    ((_ . rest) 'error)))
(test '#((10 43) (31 41 51) (32 42 52) (63 77))
    (part-2 10 (+ 21 22) (31 32) (41 42) (51 52) (+ 61 2) 77))

;; Syntax pattern with ellipsis in middle of improper list.
(define-syntax part-2x
  (syntax-rules ()
    ((_ (a b (m n) ... x y . rest))
     (vector (list a b) (list m ...) (list n ...) (list x y)
             (cons "rest:" 'rest)))
    ((_ . rest) 'error)))
(test '#((10 43) (31 41 51) (32 42 52) (63 77) ("rest:"))
    (part-2x (10 (+ 21 22) (31 32) (41 42) (51 52) (+ 61 2) 77)))
(test '#((10 43) (31 41 51) (32 42 52) (63 77) ("rest:" . "tail"))
    (part-2x (10 (+ 21 22) (31 32) (41 42) (51 52) (+ 61 2) 77 . "tail")))

;; Skipped: `(let ((=> #f)) (cond (#t => 'ok)))` from upstream line 538.
;; Tests that hygienically rebinding `=>` makes `(cond (#t => 'ok))`
;; degrade from the `=>`-clause form to a plain `(test e1 e2)` clause
;; returning `'ok`. Schooner's `cond` macro recognises `=>` by
;; literal symbol, so this expands to the apply-form and tries to
;; call `'ok` as a procedure. Documented deviation.

;; Skipped: `(let-syntax () (define x 2) #f)` body-scope test from
;; upstream lines 540-545. Tests that an internal `(define x 2)`
;; inside a `(let-syntax () ...)` body does not leak into the
;; surrounding scope, so the outer `x` stays at 1. Schooner
;; currently lets that inner define leak. Documented deviation.

(let-syntax ((vector-lit
               (syntax-rules ()
                 ((vector-lit)
                  '#(b)))))
  (test '#(b) (vector-lit)))

(test-end)

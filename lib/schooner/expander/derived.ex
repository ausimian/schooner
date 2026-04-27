defmodule Schooner.Expander.Derived do
  @moduledoc """
  Source for the bootstrap macros that re-express phase 7's derived
  forms (`cond`, `case`, `when`, `unless`, `and`, `or`, `let`, `let*`,
  `letrec`, `letrec*`, named `let`, `do`) as `syntax-rules` macros.

  The source is a string in Scheme; it is read and expanded once on
  first call to `Schooner.Expander.bootstrap_env/0`, and the resulting
  syntax env is cached via `:persistent_term`. Tests that exercise the
  derived forms therefore go through this expansion path on every run.

  ## Quasiquote

  `quasiquote` stays as a special form in `Schooner.Eval` rather than
  becoming a `syntax-rules` macro. r7rs §4.2.8 lays out a recursive,
  level-aware definition that includes vector quasiquotation; that
  level tracking is awkward to express with finite, non-recursive
  `syntax-rules` rules, and the existing evaluator implementation is
  the simpler home.
  """

  @source ~S"""
  ;; -- when / unless ---------------------------------------------------------

  (define-syntax when
    (syntax-rules ()
      ((_ test e1 e2 ...)
       (if test (begin e1 e2 ...)))))

  (define-syntax unless
    (syntax-rules ()
      ((_ test e1 e2 ...)
       (if test (begin) (begin e1 e2 ...)))))

  ;; -- and / or --------------------------------------------------------------

  (define-syntax and
    (syntax-rules ()
      ((_) #t)
      ((_ e) e)
      ((_ e1 e2 e3 ...) (if e1 (and e2 e3 ...) #f))))

  (define-syntax or
    (syntax-rules ()
      ((_) #f)
      ((_ e) e)
      ((_ e1 e2 e3 ...)
       (let ((t e1)) (if t t (or e2 e3 ...))))))

  ;; -- let family ------------------------------------------------------------
  ;;
  ;; `letrec*` stays a core special form (it's the workhorse for both
  ;; user-facing recursive bindings and internal-define splicing), so
  ;; the macros below stop at expanding to it. The named-let pattern
  ;; deliberately applies the recursive closure *inside* the letrec*
  ;; body — returning the closure and applying it outside would let
  ;; the closure outlive the rec frame and crash on first recursion.

  (define-syntax let
    (syntax-rules ()
      ((_ () body1 body2 ...)
       ((lambda () body1 body2 ...)))
      ((_ ((name val) ...) body1 body2 ...)
       ((lambda (name ...) body1 body2 ...) val ...))
      ((_ tag ((name val) ...) body1 body2 ...)
       (letrec* ((tag (lambda (name ...) body1 body2 ...)))
         (tag val ...)))))

  (define-syntax let*
    (syntax-rules ()
      ((_ () body1 body2 ...) (let () body1 body2 ...))
      ((_ ((n1 v1) (n2 v2) ...) body1 body2 ...)
       (let ((n1 v1))
         (let* ((n2 v2) ...) body1 body2 ...)))))

  (define-syntax letrec
    (syntax-rules ()
      ((_ bindings body1 body2 ...)
       (letrec* bindings body1 body2 ...))))

  ;; -- cond ------------------------------------------------------------------

  (define-syntax cond
    (syntax-rules (else =>)
      ((_) (begin))
      ((_ (else e1 e2 ...)) (begin e1 e2 ...))
      ((_ (test => proc))
       (let ((tmp test)) (if tmp (proc tmp))))
      ((_ (test => proc) clause clauses ...)
       (let ((tmp test))
         (if tmp (proc tmp) (cond clause clauses ...))))
      ((_ (test)) test)
      ((_ (test) clause clauses ...)
       (let ((tmp test)) (if tmp tmp (cond clause clauses ...))))
      ((_ (test e1 e2 ...)) (if test (begin e1 e2 ...)))
      ((_ (test e1 e2 ...) clause clauses ...)
       (if test (begin e1 e2 ...) (cond clause clauses ...)))))

  ;; -- case ------------------------------------------------------------------

  (define-syntax case
    (syntax-rules (else =>)
      ((_ key) (begin))
      ((_ key (else => proc))
       (let ((k key)) (proc k)))
      ((_ key (else e1 e2 ...))
       (begin e1 e2 ...))
      ((_ key ((d1 d2 ...) => proc))
       (let ((k key))
         (if (memv k '(d1 d2 ...)) (proc k))))
      ((_ key ((d1 d2 ...) => proc) clause clauses ...)
       (let ((k key))
         (if (memv k '(d1 d2 ...))
             (proc k)
             (case k clause clauses ...))))
      ((_ key ((d1 d2 ...) e1 e2 ...))
       (let ((k key))
         (if (memv k '(d1 d2 ...)) (begin e1 e2 ...))))
      ((_ key ((d1 d2 ...) e1 e2 ...) clause clauses ...)
       (let ((k key))
         (if (memv k '(d1 d2 ...))
             (begin e1 e2 ...)
             (case k clause clauses ...))))))

  ;; -- do --------------------------------------------------------------------
  ;;
  ;; r7rs §4.2.4: bindings without an explicit step keep their value.
  ;; The `do-step` helper macro below picks between the user-supplied
  ;; step and the variable name by pattern-matching on shape.

  (define-syntax do
    (syntax-rules ()
      ((_ ((var init step ...) ...) (test result ...) body ...)
       (letrec*
           ((loop
             (lambda (var ...)
               (if test
                   (begin (begin) result ...)
                   (begin
                     body ...
                     (loop (do-step var step ...) ...))))))
         (loop init ...)))))

  (define-syntax do-step
    (syntax-rules ()
      ((_ var) var)
      ((_ var step) step)))
  """

  @spec source() :: binary()
  def source, do: @source
end

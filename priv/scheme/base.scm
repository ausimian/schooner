;; Macros that re-express phase 7's derived forms (when, unless, and,
;; or, let, let*, letrec, cond, case, do) as syntax-rules. Loaded once
;; at boot by Schooner.Expander.bootstrap_env/0 and surfaced as the
;; macro half of the (scheme base) library by
;; Schooner.Library.Standard.boot/0.
;;
;; quasiquote stays as a special form in Schooner.Eval (r7rs §4.2.8
;; defines it level-aware over vectors as well, which is awkward to
;; express with finite, non-recursive syntax-rules rules).
;;
;; letrec* stays a core form (the workhorse for both user-facing
;; recursive bindings and internal-define splicing); the macros below
;; stop at expanding to it.

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
;; The named-let pattern deliberately applies the recursive closure
;; *inside* the letrec* body — returning the closure and applying it
;; outside would let the closure outlive the rec frame and crash on
;; first recursion.

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
;; The do-step helper macro picks between the user-supplied step and
;; the variable name by pattern-matching on shape.

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

;; -- multi-value binding ---------------------------------------------------
;;
;; Standard r7rs §4.2.2 reference implementation, using string literals
;; ("bind" / "mktmp") as helper-rule keywords to drive the binding-walk.

(define-syntax let-values
  (syntax-rules ()
    ((let-values (binding ...) body0 body1 ...)
     (let-values "bind" (binding ...) () (begin body0 body1 ...)))
    ((let-values "bind" () tmps body)
     (let tmps body))
    ((let-values "bind" ((b0 e0) binding ...) tmps body)
     (let-values "mktmp" b0 e0 () (binding ...) tmps body))
    ((let-values "mktmp" () e0 args bindings tmps body)
     (call-with-values (lambda () e0)
       (lambda args
         (let-values "bind" bindings tmps body))))
    ((let-values "mktmp" (a . b) e0 (arg ...) bindings (tmp ...) body)
     (let-values "mktmp" b e0 (arg ... x) bindings (tmp ... (a x)) body))
    ((let-values "mktmp" a e0 (arg ...) bindings (tmp ...) body)
     (call-with-values (lambda () e0)
       (lambda (arg ... . a)
         (let-values "bind" bindings (tmp ...) body))))))

(define-syntax let*-values
  (syntax-rules ()
    ((let*-values () body0 body1 ...)
     (let () body0 body1 ...))
    ((let*-values ((b0 e0) binding ...) body0 body1 ...)
     (let-values ((b0 e0))
       (let*-values (binding ...) body0 body1 ...)))))

;; -- parameterize ----------------------------------------------------------
;;
;; parameterize evaluates each parameter expression and value
;; expression left-to-right, then runs the body with each parameter
;; temporarily bound to its (converted) value. The runtime helper
;; %parameterize-apply (in Schooner.Primitives.Parameters) collects
;; the (parameter . value) pairs into a frame, applies each
;; parameter's converter, pushes the frame onto the dynamic-binding
;; stack, runs the thunk, and restores the stack on every exit path.

(define-syntax parameterize
  (syntax-rules ()
    ((_ ((p v) ...) body1 body2 ...)
     (%parameterize-apply (list (cons p v) ...)
                          (lambda () body1 body2 ...)))))

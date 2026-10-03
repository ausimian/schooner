;; (scheme lazy) macros: delay and delay-force.
;;
;; r7rs distinguishes `delay` (capture an expression to force later)
;; from `delay-force` (a tail-position promise that lets the iterative
;; force loop replace the pending promise without growing the stack).
;; Schooner does not memoise promises, so the two behave identically
;; and both expand to a lazy promise wrapping a zero-argument thunk.
;; Constant-space iteration comes from the `force` primitive, which
;; loops on its own result.
;;
;; `make-promise`, `force`, and `promise?` are primitives registered by
;; `Schooner.Primitives.Lazy` and exported from this library through
;; `Schooner.Library.Standard`.

(define-syntax delay
  (syntax-rules ()
    ((_ expr) (%lazy-from-thunk (lambda () expr)))))

(define-syntax delay-force
  (syntax-rules ()
    ((_ expr) (%lazy-from-thunk (lambda () expr)))))

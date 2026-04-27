;; (scheme lazy) macros: delay and delay-force.
;;
;; r7rs distinguishes `delay` (capture an expression to force later)
;; from `delay-force` (a tail-position promise that lets the iterative
;; force loop replace the pending promise without growing the stack).
;; Without memoisation Schooner cannot tell the two apart at the
;; observation level — both expand to a lazy promise wrapping a
;; zero-arg thunk. The iterative-tail-recursion guarantee comes from
;; the host-side `force` primitive which loops on its own result.
;;
;; The `make-promise` and `force` and `promise?` procedures are
;; primitives registered by `Schooner.Primitives.Lazy` and exported
;; from this library through `Schooner.Library.Standard`.

(define-syntax delay
  (syntax-rules ()
    ((_ expr) (%lazy-from-thunk (lambda () expr)))))

(define-syntax delay-force
  (syntax-rules ()
    ((_ expr) (%lazy-from-thunk (lambda () expr)))))

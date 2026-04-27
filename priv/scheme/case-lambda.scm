;; (scheme case-lambda) — r7rs §4.2.9
;;
;; case-lambda lowers to a chain of plain `lambda`s wrapped in a
;; rest-only outer lambda that picks the first clause whose formals
;; shape accepts the actual arity. The chain is built by recursive
;; macro expansion: each rule consumes one clause and emits a
;; `(case-lambda <remaining>)` use for the fall-through path, and the
;; empty form bottoms out into a lambda that errors on call.
;;
;; The clause shapes are dispatched by pattern alone, in this order:
;;
;;   1. `(_)`                             — no clauses left → error
;;   2. `((() body ...) ...)`             — empty fixed-arity formals
;;   3. `(((p1 p2 ...) body ...) ...)`    — proper non-empty list
;;   4. `(((p1 p2 ... . r) body ...) ...)` — dotted-rest, ≥1 fixed
;;   5. `((rest body ...) ...)`           — bare-symbol rest-only
;;
;; The order matters: the proper-list pattern must come before the
;; dotted-rest one (the latter would otherwise also match proper
;; formals and bind `r` to the empty tail), and the bare-symbol
;; pattern must come last (it matches anything as the first clause
;; element). The proper-list pattern requires ≥1 element so the empty
;; formals case has its own dedicated rule that avoids a runtime
;; `(length '())`.
;;
;; Arity discrimination is at runtime via `(length args)` against the
;; literal formals list — O(N) per clause attempt where N is the
;; clause's fixed-arity. The issue's option (a) called out the cost;
;; tests don't gate on it and the natural macro is markedly simpler
;; than carrying a compile-time-known arity through a helper macro.

(define-syntax case-lambda
  (syntax-rules ()
    ((_)
     (lambda args (error "case-lambda: no matching clause" args)))
    ((_ (() body ...) clause ...)
     (lambda args
       (if (null? args)
           ((lambda () body ...))
           (apply (case-lambda clause ...) args))))
    ((_ ((p1 p2 ...) body ...) clause ...)
     (lambda args
       (if (= (length args) (length '(p1 p2 ...)))
           (apply (lambda (p1 p2 ...) body ...) args)
           (apply (case-lambda clause ...) args))))
    ((_ ((p1 p2 ... . r) body ...) clause ...)
     (lambda args
       (if (>= (length args) (length '(p1 p2 ...)))
           (apply (lambda (p1 p2 ... . r) body ...) args)
           (apply (case-lambda clause ...) args))))
    ((_ (rest body ...) clause ...)
     (lambda rest body ...))))

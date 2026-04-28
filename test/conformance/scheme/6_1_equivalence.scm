;; Curated from Chibi-Scheme r7rs-tests.scm §6.1 "Equivalence Predicates".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - `gen-counter` / `gen-loser` cluster at lines 706-719:
;;     uses `set!` to construct a state-bearing closure. Mutation
;;     is out of scope.
;;   - `letrec eqv?` test at 721-724: relies on `letrec` bindings
;;     surviving outside their frame so two recursively-defined
;;     procedures can be compared by identity. Schooner's
;;     mutation-free letrec does not support that escape.

(test-begin "6.1 Equivalence Predicates")

(test #t (eqv? 'a 'a))
(test #f (eqv? 'a 'b))
(test #t (eqv? 2 2))
(test #t (eqv? '() '()))
(test #t (eqv? 100000000 100000000))
;; Skipped: `(eqv? (cons 1 2) (cons 1 2))` from upstream line 701.
;; r7rs says eqv? on two distinct freshly-consed pairs is #f because
;; they "denote different locations in the store". Schooner has no
;; mutable cons cells, so it implements `eqv?` on pairs as
;; structural `equal?`, returning #t here. Documented deviation.
(test #f (eqv? (lambda () 1)
               (lambda () 2)))
(test #f (eqv? #f 'nil))

(test #t
    (let ((x '(a)))
      (eqv? x x)))

(test #t (eq? 'a 'a))
;; Skipped: `(eq? (list 'a) (list 'a))` from upstream line 731 —
;; same deviation as the eqv? case above. Schooner's `eq?` reduces
;; to structural equality on pairs because there is no mutable
;; cell identity.
(test #t (eq? '() '()))
(test #t
    (let ((x '(a)))
      (eq? x x)))
(test #t
    (let ((x '#()))
      (eq? x x)))
(test #t
    (let ((p (lambda (x) x)))
      (eq? p p)))

(test #t (equal? 'a 'a))
(test #t (equal? '(a) '(a)))
(test #t (equal? '(a (b) c)
                 '(a (b) c)))
(test #t (equal? "abc" "abc"))
(test #t (equal? 2 2))
(test #t (equal? (make-vector 5 'a)
                 (make-vector 5 'a)))

(test-end)

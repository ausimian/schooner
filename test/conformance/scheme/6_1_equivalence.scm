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
(test #f (eqv? (cons 1 2) (cons 1 2)))
(test #f (eqv? (lambda () 1)
               (lambda () 2)))
(test #f (eqv? #f 'nil))

(test #t
    (let ((x '(a)))
      (eqv? x x)))

(test #t (eq? 'a 'a))
(test #f (eq? (list 'a) (list 'a)))
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

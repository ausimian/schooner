;; Curated from Chibi-Scheme r7rs-tests.scm §4.2 "Derived expression types".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - letrec* `means` test, exact-integer-sqrt cluster, and the
;;     '(x y x y) shadowing case at lines 182-238: rely on
;;     exact-integer-sqrt and rationals — neither shipped. (The
;;     `values` / `let*-values` parts are now supported but the
;;     other dependencies still gate these specific cases.)
;;   - The `(let*-values () (define ...))` scoping case at 240-246:
;;     uses an internal `define` after a `let*-values` body began,
;;     which Schooner's body desugarer rejects.
;;   - `(set! x 5)` smoke at 248-251: mutation is out of scope (PLAN.md).
;;   - `(do ... (vector-set! vec i i))` at 253-256: vector-set! is a
;;     mutator. The pure `do` summing example at 258-261 is kept.
;;   - `(set! count ...)`/`(set! x 10)` inside delay at 307-316:
;;     mutation; the surrounding promise? / make-promise tests are kept.
;;   - `make-parameter` / `parameterize` cluster: transcribed below.
;;     The upstream `radix` example uses `number->string` with an
;;     explicit base, which Schooner does not implement — substituted
;;     with arithmetic that exercises the same dynamic-binding
;;     semantics.
;;   - `square` references in quasiquote vector test at 347-348:
;;     `square` is not a Schooner primitive; the test is rewritten
;;     to use an inline `(lambda (x) (* x x))` invocation.
;;   - (Previously excluded; now restored.) The `integers` /
;;     `stream-filter` cluster at 283-305 originally exercised closures
;;     escaping their `letrec` frame and recursing afterwards. Issue
;;     #25 fixed this — escaped closures now retain access to their
;;     rec bindings via a slot kept alive in the process dictionary —
;;     so the upstream letrec-bound shape is included unchanged below.

(test-begin "4.2 Derived expression types")

(test 'greater
    (cond ((> 3 2) 'greater)
          ((< 3 2) 'less)))

(test 'equal
    (cond ((> 3 3) 'greater)
          ((< 3 3) 'less)
          (else 'equal)))

(test 2
    (cond ((assv 'b '((a 1) (b 2))) => cadr)
          (else #f)))

(test 'composite
    (case (* 2 3)
      ((2 3 5 7) 'prime)
      ((1 4 6 8 9) 'composite)))

(test 'c
    (case (car '(c d))
      ((a e i o u) 'vowel)
      ((w y) 'semivowel)
      (else => (lambda (x) x))))

(test '((other . z) (semivowel . y) (other . x)
        (semivowel . w) (vowel . u))
    (map (lambda (x)
           (case x
             ((a e i o u) => (lambda (w) (cons 'vowel w)))
             ((w y) (cons 'semivowel x))
             (else => (lambda (w) (cons 'other w)))))
         '(z y x w u)))

(test #t (and (= 2 2) (> 2 1)))
(test #f (and (= 2 2) (< 2 1)))
(test '(f g) (and 1 2 'c '(f g)))
(test #t (and))

(test #t (or (= 2 2) (> 2 1)))
(test #t (or (= 2 2) (< 2 1)))
(test #f (or #f #f #f))
(test '(b c) (or (memq 'b '(a b c))
    (/ 3 0)))

(test 6 (let ((x 2) (y 3))
  (* x y)))

(test 35 (let ((x 2) (y 3))
  (let ((x 7)
        (z (+ x y)))
    (* z x))))

(test 70 (let ((x 2) (y 3))
  (let* ((x 7)
         (z (+ x y)))
    (* z x))))

(test #t
    (letrec ((even?
              (lambda (n)
                (if (zero? n)
                    #t
                    (odd? (- n 1)))))
             (odd?
              (lambda (n)
                (if (zero? n)
                    #f
                    (even? (- n 1))))))
      (even? 88)))

(test 5
    (letrec* ((p
               (lambda (x)
                 (+ 1 (q (- x 1)))))
              (q
               (lambda (y)
                 (if (zero? y)
                     0
                     (+ 1 (p (- y 1))))))
              (x (p 5))
              (y x))
             y))

(test 25 (let ((x '(1 3 5 7 9)))
  (do ((x x (cdr x))
       (sum 0 (+ sum (car x))))
      ((null? x) sum))))

(test '((6 1 3) (-5 -2))
    (let loop ((numbers '(3 -2 1 6 -5))
               (nonneg '())
               (neg '()))
      (cond ((null? numbers) (list nonneg neg))
            ((>= (car numbers) 0)
             (loop (cdr numbers)
                   (cons (car numbers) nonneg)
                   neg))
            ((< (car numbers) 0)
             (loop (cdr numbers)
                   nonneg
                   (cons (car numbers) neg))))))

(test 3 (force (delay (+ 1 2))))

(test '(3 3)
    (let ((p (delay (+ 1 2))))
      (list (force p) (force p))))

;; Upstream Chibi shape: `next`, `head`, `tail`, `stream-filter`,
;; and `integers` are all bound by a single `letrec`. The recursive
;; calls inside the `delay`-wrapped lambdas escape the rec frame,
;; and resolve through the slot kept alive at letrec exit (issue #25).
(define integers
  (letrec ((next (lambda (n) (delay (cons n (next (+ n 1)))))))
    (next 0)))

(define head
  (lambda (stream) (car (force stream))))
(define tail
  (lambda (stream) (cdr (force stream))))

(test 2 (head (tail (tail integers))))

(define stream-filter
  (letrec ((stream-filter
            (lambda (p? s)
              (delay-force
               (if (null? (force s))
                   (delay '())
                   (let ((h (car (force s)))
                         (t (cdr (force s))))
                     (if (p? h)
                         (delay (cons h (stream-filter p? t)))
                         (stream-filter p? t))))))))
    stream-filter))

(test 5 (head (tail (tail (stream-filter odd? integers)))))

(test #t (promise? (delay (+ 2 2))))
(test #t (promise? (make-promise (+ 2 2))))
(test #t
    (let ((x (delay (+ 2 2))))
      (force x)
      (promise? x)))
(test #t
    (let ((x (make-promise (+ 2 2))))
      (force x)
      (promise? x)))
(test 4 (force (make-promise (+ 2 2))))
(test 4 (force (make-promise (make-promise (+ 2 2)))))

(test '(list 3 4) `(list ,(+ 1 2) 4))
(let ((name 'a)) (test '(list a (quote a)) `(list ,name ',name)))
(test '(a 3 4 5 6 b) `(a ,(+ 1 2) ,@(map abs '(4 -5 6)) b))
;; `square` is not a Schooner primitive; inlined as (lambda (x) (* x x)).
(test #(10 5 4 16 9 8)
    `#(10 5 ,((lambda (x) (* x x)) 2) ,@(map (lambda (x) (* x x)) '(4 3)) 8))
(test '(a `(b ,(+ 1 2) ,(foo 4 d) e) f)
    `(a `(b ,(+ 1 2) ,(foo ,(+ 1 3) d) e) f) )
(let ((name1 'x)
      (name2 'y))
   (test '(a `(b ,x ,'y d) e) `(a `(b ,,name1 ,',name2 d) e)))
(test '(list 3 4) (quasiquote (list (unquote (+ 1 2)) 4)) )
(test `(list ,(+ 1 2) 4) (quasiquote (list (unquote (+ 1 2)) 4)))

(define any-arity
  (case-lambda
    (() 'zero)
    ((x) x)
    ((x y) (cons x y))
    ((x y z) (list x y z))
    (args (cons 'many args))))

(test 'zero (any-arity))
(test 1 (any-arity 1))
(test '(1 . 2) (any-arity 1 2))
(test '(1 2 3) (any-arity 1 2 3))
(test '(many 1 2 3 4) (any-arity 1 2 3 4))

(define rest-arity
  (case-lambda
    (() '(zero))
    ((x) (list 'one x))
    ((x y) (list 'two x y))
    ((x y . z) (list 'more x y z))))

(test '(zero) (rest-arity))
(test '(one 1) (rest-arity 1))
(test '(two 1 2) (rest-arity 1 2))
(test '(more 1 2 (3)) (rest-arity 1 2 3))

(define dead-clause
  (case-lambda
    ((x . y) 'many)
    (() 'none)
    (foo 'unreachable)))

(test 'none (dead-clause))
(test 'many (dead-clause 1))
(test 'many (dead-clause 1 2))
(test 'many (dead-clause 1 2 3))

;; --- §4.2.6 dynamic bindings ---------------------------------------------
;;
;; r7rs `radix` example, adapted: Schooner has no `number->string` with a
;; base argument, so the converter is exercised directly and `(f n)`
;; multiplies its input by the current radix to make the active binding
;; observable.

(define radix
  (make-parameter
    10
    (lambda (x)
      (if (and (integer? x) (>= x 2) (<= x 16))
          x
          (error "invalid radix" x)))))

(define (f n) (* n (radix)))

(test 120 (f 12))
(test 24 (parameterize ((radix 2)) (f 12)))
(test 120 (f 12))

(test-error (parameterize ((radix 17)) (f 12)))

(test-end)

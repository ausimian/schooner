;; Curated from Chibi-Scheme r7rs-tests.scm §4.1 "Primitive expression types".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;; Chibi-Scheme is BSD-licensed; tests reproduced here verbatim except
;; where adapted for Schooner's surface (deviations called out inline).

(test-begin "4.1 Primitive expression types")

(let ()
  (define x 28)
  (test 28 x))

(test 'a (quote a))
(test #(a b c) (quote #(a b c)))
(test '(+ 1 2) (quote (+ 1 2)))

(test 'a 'a)
(test #(a b c) '#(a b c))
(test '() '())
(test '(+ 1 2) '(+ 1 2))
(test '(quote a) '(quote a))
(test '(quote a) ''a)

(test "abc" '"abc")
(test "abc" "abc")
(test 145932 '145932)
(test 145932 145932)
(test #t '#t)
(test #t #t)

(test 7 (+ 3 4))
(test 12 ((if #f + *) 3 4))

(test 8 ((lambda (x) (+ x x)) 4))
(define reverse-subtract
  (lambda (x y) (- y x)))
(test 3 (reverse-subtract 7 10))
(define add4
  (let ((x 4))
    (lambda (y) (+ x y))))
(test 10 (add4 6))

(test '(3 4 5 6) ((lambda x x) 3 4 5 6))
(test '(5 6) ((lambda (x y . z) z) 3 4 5 6))

(test 'yes (if (> 3 2) 'yes 'no))
(test 'no (if (> 2 3) 'yes 'no))
(test 1 (if (> 3 2) (- 3 2) (+ 3 2)))

(let ()
  (define x 2)
  (test 3 (+ x 1)))

(test-end)

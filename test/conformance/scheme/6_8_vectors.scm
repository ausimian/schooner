;; Curated from Chibi-Scheme r7rs-tests.scm §6.8 "Vectors".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - `(round (* 2 (acos -1)))` flavour of `vector-ref` index test
;;     at lines 1496-1500: relies on `exact` to coerce the float
;;     to an integer index. `exact`/`inexact` aren't in Schooner's
;;     surface; the simpler integer-index test is kept.
;;   - `vector-set!` test at lines 1502-1504: mutation; out of scope.
;;   - All `vector-fill!` tests at 1533-1540: mutation.
;;   - All `vector-copy!` tests at 1542-1557: mutation.

(test-begin "6.8 Vectors")

(test #t (vector? #()))
(test #t (vector? #(1 2 3)))
(test #t (vector? '#(1 2 3)))

(test 0 (vector-length (make-vector 0)))
(test 1000 (vector-length (make-vector 1000)))

(test #(0 (2 2 2 2) "Anna") '#(0 (2 2 2 2) "Anna"))

(test #(a b c) (vector 'a 'b 'c))

(test 8 (vector-ref '#(1 1 2 3 5 8 13 21) 5))

(test '(dah dah didah) (vector->list '#(dah dah didah)))
(test '(dah didah) (vector->list '#(dah dah didah) 1))
(test '(dah) (vector->list '#(dah dah didah) 1 2))
(test #(dididit dah) (list->vector '(dididit dah)))

(test #() (vector-copy #()))
(test #(a b c) (vector-copy #(a b c)))
(test #(b c) (vector-copy #(a b c) 1))
(test #(b) (vector-copy #(a b c) 1 2))

(test #() (vector-append #()))
(test #() (vector-append #() #()))
(test #(a b c) (vector-append #() #(a b c)))
(test #(a b c) (vector-append #(a b c) #()))
(test #(a b c d e) (vector-append #(a b c) #(d e)))
(test #(a b c d e f) (vector-append #(a b c) #(d e) #(f)))

(test-end)

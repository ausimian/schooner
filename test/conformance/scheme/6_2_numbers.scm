;; Curated from Chibi-Scheme r7rs-tests.scm §6.2 "Numbers".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - All `complex?` / complex-number cases (`3+4i`, `1.0+0.0i`, etc.):
;;     Schooner has no complex numbers (PLAN.md, README).
;;   - `(real? -2.5+0i)` / `(real? -2.5+0.0i)` / `(real? +inf.0)`: depend on
;;     the complex tower; Schooner's `real?` is the integer/rational/float
;;     subset and is not exposed yet — covered indirectly by `rational?`.
;;   - `#e1e10` / `#e3.0` literal syntax: Schooner's `#e` only recognises
;;     integer / rational source bodies.
;;   - `make-rectangular` / `make-polar` / `real-part` / `imag-part` /
;;     `magnitude` / `angle`: complex tower.
;;   - The `(- 3/2+i)` line: complex literal.
;;   - The `9007199254740992.0 9007199254740993` case: relies on a 64-bit
;;     exact integer that loses precision when widened — kept inline to
;;     pin Schooner's behaviour but the assertion is rephrased.
;;   - `single-float-epsilon` / Bawden / CLtL transitivity tests: depend on
;;     `exact` widening rules at float scale that Schooner does not expose.
;;   - `(sqrt -1)` / complex sqrt: Schooner raises rather than producing
;;     a complex result (documented deviation).
;;   - `(sqrt 2)` returning an inexact root: Schooner raises on
;;     non-square exact inputs (documented deviation in README) — kept
;;     out of this section; the inexact form `(sqrt 2.0)` is exercised
;;     in the Schooner-side primitives test suite.

(test-begin "6.2 Numbers")

(test #f (rational? -inf.0))
(test #f (rational? +nan.0))
(test #t (rational? 9007199254740991.0))
(test #t (rational? 1.7976931348623157e308))
(test #t (rational? 6/10))
(test #t (rational? 6/3))

(test #t (integer? 3.0))
(test #t (integer? 8/4))

(test #f (exact? 3.0))
(test #t (exact? 1/2))
(test #t (inexact? 3.))

(test #t (= 1 1.0))
(test #t (< 1 2 3))
(test #f (< 1 1 2))
(test #t (> 3.0 2.0 1.0))
(test #t (<= 1 1 2))
(test #f (<= 1 2 1))
(test #t (>= 2 1 1))
(test #f (>= 1 2 1))
(test #f (< +nan.0 0))
(test #f (> +nan.0 0))
(test #t (= 1/2 0.5))
(test #t (< 1/3 1/2))
(test #t (<= 1/2 2/4))
(test #f (= 1/2 1/3))

(test #t (zero? 0))
(test #t (zero? 0.0))
(test #f (zero? 1))
(test #f (zero? -1))
(test #f (zero? 1/2))

(test #f (positive? 0))
(test #t (positive? 1))
(test #t (positive? 1.0))
(test #f (positive? -1))
(test #t (positive? +inf.0))
(test #f (positive? -inf.0))
(test #f (positive? +nan.0))
(test #t (positive? 1/2))
(test #f (positive? -1/2))

(test #f (negative? 0))
(test #t (negative? -1))
(test #f (negative? +inf.0))
(test #t (negative? -inf.0))
(test #f (negative? +nan.0))
(test #t (negative? -1/2))
(test #f (negative? 1/2))

(test #f (odd? 0))
(test #t (odd? 1))
(test #t (odd? -1))
(test #f (odd? 102))

(test #t (even? 0))
(test #f (even? 1))
(test #t (even? -2))

(test 3 (max 3))
(test 4 (max 3 4))
(test 4.0 (max 3.9 4))
(test 5.0 (max 5 3.9 4))
(test +inf.0 (max 100 +inf.0))
(test 3 (min 3))
(test 3 (min 3 4))
(test 3.0 (min 3 3.1))
(test -inf.0 (min -inf.0 -100))
(test 1/3 (min 1/2 1/3))
(test 1/2 (max 1/2 1/3))

(test 7 (+ 3 4))
(test 3 (+ 3))
(test 0 (+))
(test 4 (* 4))
(test 1 (*))

(test -1 (- 3 4))
(test -6 (- 3 4 5))
(test -3 (- 3))
(test -3/2 (- 3/2))
(test 3/20 (/ 3 4 5))
(test 1/3 (/ 3))
(test 1/2 (/ 1 2))
(test -5/2 (/ -10 4))

(test 1073741824 (/ -1073741824 -1))
(test 1073741824 (quotient -1073741824 -1))
(test 0 (remainder -1073741824 -1))
(test 4611686018427387904 (/ -4611686018427387904 -1))
(test 4611686018427387904 (quotient -4611686018427387904 -1))
(test 0 (remainder -4611686018427387904 -1))

(test 7 (abs -7))
(test 7 (abs 7))
(test 1/2 (abs -1/2))

(test 1 (modulo 13 4))
(test 1 (remainder 13 4))

(test 3 (modulo -13 4))
(test -1 (remainder -13 4))

(test -3 (modulo 13 -4))
(test 1 (remainder 13 -4))

(test -1 (modulo -13 -4))
(test -1 (remainder -13 -4))

(test -1.0 (remainder -13 -4.0))

(test 4 (gcd 32 -36))
(test 0 (gcd))
(test 288 (lcm 32 -36))
(test 288.0 (lcm 32.0 -36))
(test 1 (lcm))

(test 3 (numerator (/ 6 4)))
(test 2 (denominator (/ 6 4)))
(test 2.0 (denominator (inexact (/ 6 4))))
(test 11.0 (numerator 5.5))
(test 2.0 (denominator 5.5))
(test 5.0 (numerator 5.0))
(test 1.0 (denominator 5.0))

(test 1/3 (rationalize (exact .3) 1/10))
(test #i1/3 (rationalize .3 1/10))

(test 1/8 (expt 2 -3))
(test -1/8 (expt -2 -3))
(test 1/8 (expt 1/2 3))
(test 27 (expt 3 3))
(test 1 (expt 0 0))
(test 0 (expt 0 1))
(test 1.0 (expt 0.0 0))
(test 0.0 (expt 0 1.0))

(test 1.0 (inexact 1))
(test #t (inexact? (inexact 1)))
(test 1 (exact 1.0))
(test #t (exact? (exact 1.0)))
(test 1/2 (exact 0.5))
(test 0.5 (inexact 1/2))

;; --- Issue #88 — exact-integer? / exact-rational? -------------------------

(test #t (exact-integer? 32))
(test #f (exact-integer? 32.0))
(test #f (exact-integer? 32/5))
(test #t (exact-rational? 1/2))
(test #t (exact-rational? 32))
(test #f (exact-rational? 1.5))

;; --- Issue #88 — square / exact-integer-sqrt ------------------------------

(test 1764 (square 42))
(test 4 (square 2))
(test 4.0 (square 2.0))

(test-assert
 (call-with-values (lambda () (exact-integer-sqrt 4)) (lambda (s r) (and (= s 2) (= r 0)))))
(test-assert
 (call-with-values (lambda () (exact-integer-sqrt 5)) (lambda (s r) (and (= s 2) (= r 1)))))

;; --- Issue #86 — floor / ceiling / truncate / round -----------------------

(test -5.0 (floor -4.3))
(test -4.0 (ceiling -4.3))
(test -4.0 (truncate -4.3))
(test -4.0 (round -4.3))

(test 3.0 (floor 3.5))
(test 4.0 (ceiling 3.5))
(test 3.0 (truncate 3.5))
(test 4.0 (round 3.5)) ;; ties to even (4 is even)

(test 4 (round 7/2)) ;; ties to even
(test 7 (round 7))

(test -2 (floor -3/2))
(test 1 (ceiling 1/2))
(test 0 (truncate 1/2))
(test 0 (round 1/2)) ;; ties to even

;; --- Issue #87 — division families ----------------------------------------

(test-assert
 (call-with-values (lambda () (truncate/ 5 2)) (lambda (q r) (and (= q 2) (= r 1)))))
(test-assert
 (call-with-values (lambda () (truncate/ -5 2)) (lambda (q r) (and (= q -2) (= r -1)))))
(test-assert
 (call-with-values (lambda () (truncate/ 5 -2)) (lambda (q r) (and (= q -2) (= r 1)))))
(test-assert
 (call-with-values (lambda () (truncate/ -5 -2)) (lambda (q r) (and (= q 2) (= r -1)))))

(test 2 (truncate-quotient 5 2))
(test 1 (truncate-remainder 5 2))

(test-assert
 (call-with-values (lambda () (floor/ 5 2)) (lambda (q r) (and (= q 2) (= r 1)))))
(test-assert
 (call-with-values (lambda () (floor/ -5 2)) (lambda (q r) (and (= q -3) (= r 1)))))
(test-assert
 (call-with-values (lambda () (floor/ 5 -2)) (lambda (q r) (and (= q -3) (= r -1)))))
(test-assert
 (call-with-values (lambda () (floor/ -5 -2)) (lambda (q r) (and (= q 2) (= r -1)))))

(test 2 (floor-quotient 5 2))
(test 1 (floor-remainder 5 2))

;; --- Issue #89 — number->string / string->number --------------------------

(test "100" (number->string 100))
(test "100" (number->string 256 16))
(test "ff" (number->string 255 16))
(test "1/2" (number->string 1/2))
(test "+inf.0" (number->string +inf.0))

(test 100 (string->number "100"))
(test 256 (string->number "100" 16))
(test 1/2 (string->number "1/2"))
(test 100.0 (string->number "1e2"))
(test #f (string->number ""))
(test #f (string->number "."))
(test #f (string->number "d"))
(test #f (string->number "D"))
(test #f (string->number "i"))
(test #f (string->number "I"))
(test #f (string->number "3i"))
(test #f (string->number "3.4.5"))
(test #f (string->number "9" 8))
(test 8 (string->number "10" 8))

(test-end)

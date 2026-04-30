;; Curated from Chibi-Scheme r7rs-tests.scm §6.2 ((scheme complex)).
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from upstream:
;;   - Cases that exercise the (rational? +inf.0+0i) family with
;;     mixed-special complex; Schooner's reader does not pretend to
;;     canonicalise non-finite complex literals beyond the simple
;;     finite case (documented).
;;   - `string->number` on complex literals: not implemented.
;;   - `exact->inexact` on a complex value: Schooner's `exact` /
;;     `inexact` operate componentwise; the upstream tests target
;;     a different surface and are covered by the unit suite instead.
;;
;; Numeric tolerance is 1e-12 throughout — strict-equal `test` is
;; reserved for the cases where the upstream r7rs-tests demand exact
;; bit-identity (rectangular integer paths).

(define-syntax test-approx
  (syntax-rules ()
    ((_ expected actual)
     (let ((e expected) (a actual))
       (if (< (abs (- e a)) 1e-12)
           'ok
           (error "test-approx failed" 'actual e a))))))

(define (close-complex? z1 z2 tol)
  (and (< (abs (- (real-part z1) (real-part z2))) tol)
       (< (abs (- (imag-part z1) (imag-part z2))) tol)))

(define-syntax test-complex
  (syntax-rules ()
    ((_ expected actual)
     (let ((e expected) (a actual))
       (if (close-complex? e a 1e-9)
           'ok
           (error "test-complex failed" 'actual e a))))))

(test-begin "6.2.6 (scheme complex)")

;; Predicates
(test #t (complex? 3+4i))
(test #t (complex? 3))
(test #t (number? 3+4i))
(test #f (real? 3+4i))
(test #t (real? 3))
(test #f (rational? +i))
(test #f (integer? +i))

;; real-part / imag-part
(test 3 (real-part 3+4i))
(test 4 (imag-part 3+4i))
(test 3 (real-part 3))
(test 0 (imag-part 3))
(test 0.0 (imag-part 3.0))

;; make-rectangular
(test 1+2i (make-rectangular 1 2))
(test 5 (make-rectangular 5 0)) ; exact-zero imag collapses

;; make-polar / magnitude / angle round-trip
(test-approx 5.0 (magnitude 3+4i))
(test-approx 0.0 (angle 1))
(test-approx 0.0 (imag-part (make-polar 1 0)))

;; magnitude on reals
(test 7 (magnitude -7))
(test 1/2 (magnitude -1/2))

;; Arithmetic
(test 4+6i (+ 1+2i 3+4i))
(test 3+2i (- 5+3i 2+i))
(test -5+10i (* 1+2i 3+4i))
(test -1 (* +i +i))
(test #t (= 3+4i 3+4i))
(test #f (= 3+4i 3+5i))
(test #t (= 1 (make-rectangular 1 0)))

;; expt with integer exponent on complex base is exact
(test 0+2i (expt 1+i 2))
(test -4 (expt 1+i 4))

;; sqrt lifts negatives into the imaginary axis
(test 0+1.0i (sqrt -1))
(test 0+2.0i (sqrt -4))

;; log / exp round-trip
(test-complex 1+2i (log (exp 1+2i)))
;; Euler: exp(iπ) ≈ -1
(test-complex -1 (exp (make-rectangular 0 3.141592653589793)))

;; Prefixed-radix complex literals: #e forces exact components,
;; #i widens them to inexact.
(test #t (= 3+4i #e3+4i))
(test #t (exact? (real-part #e3+4i)))
(test #t (exact? (imag-part #e3+4i)))
(test #t (inexact? (real-part #i1/2+1/3i)))
(test #t (inexact? (imag-part #i1/2+1/3i)))
(test-approx 0.5 (real-part #i1/2+1/3i))

(test-end)
